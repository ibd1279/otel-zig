//! Basic Periodic Metrics Processor
//!
//! This module provides a basic metrics processor that collects metrics from registered
//! meters on a periodic basis using a background thread. It uses POSIX threads
//! for cross-platform compatibility.
//!
//! The processor maintains a thread that wakes up at regular intervals to collect
//! metrics from all registered meters and export them via the configured exporter.

const std = @import("std");
const api = @import("otel-api");
const c = std.c;

const sdk = struct {
    const BridgeReader = @import("reader.zig").BridgeReader;
    const Meter = @import("meter.zig").Meter;
    const MeterProvider = @import("meter_provider.zig").MeterProvider;
    const MetricData = @import("data.zig").MetricData;
    const Reader = @import("reader.zig").Reader;
    const MetricExporter = @import("exporter.zig").MetricExporter;
    const ReaderAggregationState = @import("reader_aggregation_state.zig").ReaderAggregationState;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("reader.zig").MetricValue;
    const Resource = @import("../resource/resource.zig").Resource;
};

/// Basic periodic metrics processor that collects metrics at regular intervals
pub const PeriodicReader = struct {
    pub const Config = struct {
        io: std.Io,
        interval_ms: ?u32 = null,
    };

    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        PeriodicReader,
        sdk.Reader,
        Config,
        reader,
        _initFn,
        setExporter,
    );
    pub fn _initFn(self: *PeriodicReader, ctx: Config, allocator: std.mem.Allocator) !void {
        self.* = try init(allocator, ctx.io, null, ctx.interval_ms);
        try self.start();
    }

    allocator: std.mem.Allocator,
    io: std.Io,
    exporter: ?sdk.MetricExporter,
    mutex: std.Io.Mutex,
    condition: std.Io.Condition,
    is_shutdown: std.atomic.Value(bool),
    is_running: std.atomic.Value(bool),
    collection_in_progress: std.atomic.Value(bool),
    collection_complete: std.Io.Condition,
    /// Signaled in deinit() to wake the collection thread immediately
    /// rather than waiting up to collection_interval_ms for the sleep to expire.
    shutdown_signal: std.Io.Event,
    thread: ?std.Thread,
    collection_interval_ms: u32,
    registered_meters: std.ArrayListUnmanaged(*sdk.Meter),
    reader_state: sdk.ReaderAggregationState,
    resource: sdk.Resource = sdk.Resource.empty,

    /// Initialize a new basic periodic metrics processor
    /// collection_interval_ms: How often to collect metrics (default: 60000ms = 60s)
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        exporter: ?sdk.MetricExporter,
        collection_interval_ms: ?u32,
    ) !PeriodicReader {
        return .{
            .allocator = allocator,
            .io = io,
            .exporter = exporter,
            .mutex = std.Io.Mutex.init,
            .condition = std.Io.Condition.init,
            .is_shutdown = std.atomic.Value(bool).init(false),
            .is_running = std.atomic.Value(bool).init(false),
            .collection_in_progress = std.atomic.Value(bool).init(false),
            .collection_complete = std.Io.Condition.init,
            .shutdown_signal = .unset,
            .thread = null,
            .collection_interval_ms = collection_interval_ms orelse 60000, // 60 seconds default
            .registered_meters = .empty,
            .reader_state = try sdk.ReaderAggregationState.init(
                allocator,
                .delta, // Default to Delta temporality for now
                @import("reader_aggregation_state.zig").defaultAggregationSelector,
            ),
        };
    }

    /// Start the background collection thread
    pub fn start(self: *PeriodicReader) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_running.load(.acquire) or self.thread != null) {
            return;
        }

        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, collectionThreadFn, .{self});
    }

    /// Stop the background collection thread and clean up resources
    pub fn deinit(self: *PeriodicReader) void {
        // Signal shutdown and wake the collection thread immediately
        // (without the signal it would sleep for up to collection_interval_ms).
        self.is_shutdown.store(true, .release);
        self.is_running.store(false, .release);
        self.shutdown_signal.set(self.io);

        // Wait for thread to finish
        if (self.thread) |thread| {
            thread.join();
        }

        // Clean up resources
        self.reader_state.deinit();
        self.registered_meters.deinit(self.allocator);
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    /// Destroy the processor and free its memory
    pub fn destroy(self: *PeriodicReader) void {
        self.allocator.destroy(self);
    }

    pub fn recordMeasurement(
        self: *PeriodicReader,
        value: sdk.MetricValue,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
    ) void {
        self.reader_state.recordMeasurement(value, attributes, metadata, metadata_hash);
    }

    /// Collect metrics from all registered meters.
    ///
    /// Must lock mutex before calling.
    /// collection_in_progress must be false before calling.
    fn internalCollect(self: *PeriodicReader) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // flag that we are in process.
        if (self.collection_in_progress.swap(true, .acq_rel)) {
            // It was already already true, so we aren't the first to get here.
            api.common.reportError(.{
                .component = .meter,
                .context = null,
                .error_type = .internal,
                .message = "Collection while Collection already in progress.",
                .operation = "PeriodicReader.internalCollect",
                .source_error = null,
            });
            return;
        }

        // at this point we are the lucky thread that got false when it did the swap above.
        defer {
            self.collection_in_progress.store(false, .release);
            self.collection_complete.broadcast(self.io);
        }

        // trigger the observables to write their data to the aggregation state.
        for (self.registered_meters.items) |meter| {
            meter.triggerObservables(allocator, self.reader());
        }

        // Collect all the aggregated metrics.
        const collected_metrics = self.reader_state.collect(allocator, self.io, self.resource) catch |err| {
            std.log.err("Failed to collect metrics: {}", .{err});
            // Log error if needed
            return;
        };
        defer allocator.free(collected_metrics);

        // Export all collected metrics. Exporter must copy memory
        // that it needs beyond the duration of this call.
        if (self.exporter) |*exporter| _ = exporter.exportMetrics(collected_metrics);
        // Arena cleans up all the memory.
    }

    pub fn collect(self: *PeriodicReader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.collection_in_progress.load(.acquire)) {
            self.collection_complete.waitUncancelable(self.io, &self.mutex);
        }

        self.internalCollect();
    }

    /// Force flush the exporter
    pub fn forceFlush(self: *PeriodicReader, timeout_ms: ?u64) api.common.FlushResult {
        const start_ts = std.Io.Clock.real.now(self.io);

        // force flush has to cascade to the exporter as well, but we don't need to hold the mutex for that part.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // Wait for any existing collection to complete
            while (self.collection_in_progress.load(.acquire)) {
                if (timeout_ms) |collection_timeout| {
                    const now_ts = std.Io.Clock.real.now(self.io);
                    const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(now_ts.nanoseconds - start_ts.nanoseconds, std.time.ns_per_ms)));
                    if (elapsed_ms >= collection_timeout) return .timeout;
                    self.collection_complete.waitUncancelable(self.io, &self.mutex);
                } else {
                    self.collection_complete.waitUncancelable(self.io, &self.mutex);
                }
            }
            self.internalCollect();
        }

        // Flush the exporter
        return if (self.exporter) |exporter| blk: {
            if (timeout_ms) |collection_timeout| {
                const now_ts = std.Io.Clock.real.now(self.io);
                const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(now_ts.nanoseconds - start_ts.nanoseconds, std.time.ns_per_ms)));
                if (elapsed_ms >= collection_timeout) return .timeout;
                break :blk exporter.forceFlush(collection_timeout - elapsed_ms).asFlushResult();
            } else {
                break :blk exporter.forceFlush(null).asFlushResult();
            }
        } else .success;
    }

    /// Shutdown the processor
    pub fn shutdown(self: *PeriodicReader, timeout_ms: ?u64) api.common.ProcessResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown.swap(true, .seq_cst)) {
            return .success;
        }

        self.is_running.store(false, .release);
        self.condition.signal(self.io);

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    /// Register a meter for periodic collection
    pub fn registerMeter(self: *PeriodicReader, meter: *sdk.Meter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown.load(.acquire)) return;

        self.registered_meters.append(self.allocator, meter) catch |err| {
            api.common.reportError(.{
                .component = .meter,
                .operation = "registerMeter",
                .error_type = .resource_exhausted,
                .message = "Failed to register meter with periodic reader",
                .source_error = err,
            });
            return;
        };
    }

    /// Unregister a meter from periodic collection
    pub fn unregisterMeter(self: *PeriodicReader, meter: *sdk.Meter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown.load(.acquire)) return;

        for (self.registered_meters.items, 0..) |registered_meter, i| {
            if (registered_meter == meter) {
                _ = self.registered_meters.swapRemove(i);
                break;
            }
        }
    }

    /// Unregister all meters from periodic collection
    pub fn unregisterAllMeters(self: *PeriodicReader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.registered_meters.clearAndFree(self.allocator);
    }

    pub fn setResource(self: *PeriodicReader, resource: sdk.Resource) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.resource = resource;
    }

    /// Set the exporter for this processor
    pub fn setExporter(self: *PeriodicReader, exporter: ?sdk.MetricExporter) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    /// Get the processor as a MetricProcessor union
    pub fn reader(self: *PeriodicReader) sdk.Reader {
        return .{ .bridge = sdk.BridgeReader.init(self) };
    }

    /// Background thread function that periodically collects metrics
    fn collectionThreadFn(self: *PeriodicReader) void {
        while (true) {
            if (self.is_shutdown.load(.acquire)) break;

            // Sleep for the collection interval or until signaled for shutdown.
            const raw = std.Io.Duration.fromMilliseconds(@intCast(self.collection_interval_ms));
            const timeout = std.Io.Timeout{ .duration = .{ .raw = raw, .clock = .awake } };
            self.shutdown_signal.waitTimeout(self.io, timeout) catch {};
            self.shutdown_signal.reset();

            if (self.is_shutdown.load(.acquire)) break;

            if (self.collection_in_progress.load(.acquire)) {
                // Already collecting, skip this cycle
                continue;
            }

            // Acquire mutex to match collect() and forceFlush() — prevents
            // registerMeter/unregisterMeter from mutating registered_meters
            // while internalCollect iterates it.
            self.mutex.lockUncancelable(self.io);
            self.internalCollect();
            self.mutex.unlock(self.io);
        }
    }
};

test "BasicPeriodicProcessor - direct init vs pipeline init thread behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const MockExporter = @import("exporter.zig").MockMetricExporter;

    // Create mock exporter
    const mock_exporter = try allocator.create(MockExporter);
    mock_exporter.* = MockExporter.init(allocator);

    // Create a provider to tie all the parts together.
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, sdk.Resource.empty);
    defer provider.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // Create processor with very short interval for testing (direct init)
    const processor = try allocator.create(PeriodicReader);
    {
        errdefer allocator.destroy(processor);
        processor.* = try PeriodicReader.init(allocator, io, mock_exporter.metricExporter(), 100); // 100ms
        {
            errdefer processor.deinit();
            try provider.registerReader(processor.reader());
        }
    }

    // Verify thread is not running when created via direct init()
    try testing.expect(!processor.is_running.load(.acquire));
    try testing.expect(processor.thread == null);

    // Create a basic meter for testing
    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    _ = provider.getMeterWithScope(scope);

    // Start the thread manually (since we're not using pipeline)
    try processor.start();

    // Verify thread is now running
    try testing.expect(processor.is_running.load(.acquire));
    try testing.expect(processor.thread != null);

    // Create a second meter
    const scope2 = api.InstrumentationScope{ .name = "test.meter2", .version = "1.0.0" };
    _ = provider.getMeterWithScope(scope2);

    // Verify thread is still running and we have both meters
    try testing.expect(processor.is_running.load(.acquire));
    try testing.expect(processor.thread != null);
    try testing.expect(processor.registered_meters.items.len == 2);

    // Wait a bit to allow some collections to happen
    try std.Io.sleep(std.testing.io, .{ .nanoseconds = 250 * std.time.ns_per_ms }, .awake);

    // Verify some exports happened (thread is working)
    const export_count = mock_exporter.exportCount();
    try testing.expect(export_count > 0);

    // Test shutdown - should stop the thread
    _ = processor.shutdown(1000);
    try testing.expect(processor.is_shutdown.load(.acquire));

    // Give thread time to exit
    try std.Io.sleep(std.testing.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake);
}

test "BasicPeriodicProcessor - no thread start without meters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create processor
    var processor = try PeriodicReader.init(allocator, std.testing.io, null, 100);
    defer processor.deinit();

    // Verify thread is not running
    try testing.expect(!processor.is_running.load(.acquire));
    try testing.expect(processor.thread == null);

    // Call forceFlush - should not crash
    const result = processor.forceFlush(100);
    try testing.expect(result == .success);

    // Thread should still not be running
    try testing.expect(!processor.is_running.load(.acquire));
    try testing.expect(processor.thread == null);

    // Shutdown should work fine
    _ = processor.shutdown(100);
    try testing.expect(processor.is_shutdown.load(.acquire));
}

test "PeriodicReader and Observable instrument test." {
    const testing = std.testing;
    const allocator = testing.allocator;
    const MockExporter = @import("exporter.zig").MockMetricExporter;

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockExporter);
    mock_exporter.* = MockExporter.init(allocator);

    // Create a provider to tie all the parts together.
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, sdk.Resource.empty);
    defer provider.deinit();

    // Create processor with very short interval for testing (direct init)
    const processor = try allocator.create(PeriodicReader);
    {
        errdefer allocator.destroy(processor);
        processor.* = try PeriodicReader.init(allocator, io, mock_exporter.metricExporter(), 100); // 100ms
        {
            errdefer processor.deinit();
            try provider.registerReader(processor.reader());
        }
    }

    try processor.start();

    const scope = api.InstrumentationScope{ .name = "cardinality", .version = "1.0.0" };
    var meter = provider.getMeterWithScope(scope);
    const ctx = &[_]api.ContextKeyValue{};

    const CbStruct = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(i64), context: *anyopaque) void {
            const self: *PeriodicReader = @ptrCast(@alignCast(context));
            const cardinality = self.reader_state.aggregations.getCardinality();
            result.observeValue(alloc, @intCast(cardinality));
        }
    };

    const instrument = try meter.createObservableGauge(
        i64,
        "reader.cardinality",
        "how many active buckets in the reader aggregation.",
        "1",
        null,
        &[_]api.metrics.TypeErasedCallback(i64){},
    );

    _ = try instrument.registerCallback(PeriodicReader, CbStruct.callback, processor);

    const up_down = try meter.createCounter(i64, "foo", null, "1", null);
    for (0..15) |i| {
        const attributes = try api.AttributeBuilder.init(allocator)
            .add(.{ .key = "bar", .value = .{ .string = "baz" } })
            .add(.{ .key = "basic", .value = .{ .int = @intCast(i % 4) } })
            .finish(allocator);
        defer api.AttributeKeyValue.deinitOwnedSlice(allocator, attributes);
        up_down.add(ctx, 1, attributes);
        if (i % 12 == 0) {
            processor.collect();
        }
    }

    _ = provider.shutdown(null);

    var found = false;
    for (mock_exporter.exported_metrics.items) |value| {
        if (std.mem.eql(u8, value.name, instrument.getName())) {
            found = true;
        }
    }
    try testing.expect(found);
}
