//! OpenTelemetry Basic Metric Processor
//!
//! This module provides the BasicMetricProcessor that exports metrics immediately
//! when collected. It's the simplest metric processor implementation.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md#metricreader

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const BridgeMetricReader = @import("reader.zig").BridgeReader;
    const Meter = @import("meter.zig").Meter;
    const MeterProvider = @import("meter_provider.zig").MeterProvider;
    const MetricExporter = @import("exporter.zig").MetricExporter;
    const Reader = @import("reader.zig").Reader;
    const MetricData = @import("data.zig").MetricData;
    const ReaderAggregationState = @import("reader_aggregation_state.zig").ReaderAggregationState;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("reader.zig").MetricValue;
    const Resource = @import("../resource/resource.zig").Resource;
};

/// Basic log processor implementation.
///
/// Simple processor that exports metrics manually. Users must invoke `forceFlush`.
pub const ManualReader = struct {
    pub const Config = struct {
        io: std.Io,
    };

    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        ManualReader,
        sdk.Reader,
        Config,
        reader,
        _initFn,
        setExporter,
    );
    pub fn _initFn(self: *ManualReader, ctx: Config, allocator: std.mem.Allocator) !void {
        self.* = try init(allocator, ctx.io, null);
    }

    allocator: std.mem.Allocator,
    io: std.Io,
    exporter: ?sdk.MetricExporter,
    mutex: std.Io.Mutex,
    is_shutdown: bool,
    registered_meters: std.ArrayListUnmanaged(*sdk.Meter),
    reader_state: sdk.ReaderAggregationState,
    resource: sdk.Resource = sdk.Resource.empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, exporter: ?sdk.MetricExporter) !ManualReader {
        return .{
            .allocator = allocator,
            .io = io,
            .exporter = exporter,
            .mutex = std.Io.Mutex.init,
            .is_shutdown = false,
            .registered_meters = .empty,
            .reader_state = try sdk.ReaderAggregationState.init(
                allocator,
                .delta, // Default to Delta temporality for now
                @import("reader_aggregation_state.zig").defaultAggregationSelector,
            ),
        };
    }

    pub fn deinit(self: *ManualReader) void {
        self.reader_state.deinit();
        self.registered_meters.deinit(self.allocator);
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *ManualReader) void {
        self.allocator.destroy(self);
    }

    pub fn setExporter(self: *ManualReader, exporter: ?sdk.MetricExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    pub fn recordMeasurement(
        self: *ManualReader,
        value: sdk.MetricValue,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
    ) void {
        self.reader_state.recordMeasurement(value, attributes, metadata, metadata_hash);
    }

    pub fn collect(self: *ManualReader) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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

    pub fn forceFlush(self: *ManualReader, timeout_ms: ?u64) api.common.FlushResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = if (self.exporter) |*exporter| exporter.forceFlush(timeout_ms) else .success;
        return result.asFlushResult();
    }

    pub fn shutdown(self: *ManualReader, timeout_ms: ?u64) api.common.ProcessResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return result.asFlushResult().asProcessResult();
    }

    pub fn registerMeter(self: *ManualReader, meter: *sdk.Meter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown) return;

        self.registered_meters.append(self.allocator, meter) catch {
            // Handle allocation failure silently for now
            return;
        };
    }

    pub fn unregisterMeter(self: *ManualReader, meter: *sdk.Meter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown) return;

        for (self.registered_meters.items, 0..) |registered_meter, i| {
            if (registered_meter == meter) {
                _ = self.registered_meters.swapRemove(i);
                break;
            }
        }
    }

    pub fn unregisterAllMeters(self: *ManualReader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.registered_meters.clearAndFree(self.allocator);
    }

    pub fn setResource(self: *ManualReader, resource: sdk.Resource) void {
        self.resource = resource;
    }

    pub fn reader(self: *ManualReader) sdk.Reader {
        return .{ .bridge = sdk.BridgeMetricReader.init(self) };
    }
};

test "ManualReader and Observable instrument test." {
    const testing = std.testing;
    const allocator = testing.allocator;
    const MockExporter = @import("exporter.zig").MockMetricExporter;

    // Create mock exporter
    const mock_exporter = try allocator.create(MockExporter);
    mock_exporter.* = MockExporter.init(allocator);

    // Create a provider to tie all the parts together.
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, sdk.Resource.empty);
    defer provider.deinit();

    // Create processor with very short interval for testing (direct init)
    const processor = try allocator.create(ManualReader);
    {
        errdefer allocator.destroy(processor);
        processor.* = try ManualReader.init(allocator, std.testing.io, mock_exporter.metricExporter());
        {
            errdefer processor.deinit();
            try provider.registerReader(processor.reader());
        }
    }

    const scope = api.InstrumentationScope{ .name = "cardinality", .version = "1.0.0" };
    var meter = provider.getMeterWithScope(scope);
    const ctx = &[_]api.ContextKeyValue{};

    const CbStruct = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(i64), context: *anyopaque) void {
            const self: *ManualReader = @ptrCast(@alignCast(context));
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

    _ = try instrument.registerCallback(ManualReader, CbStruct.callback, processor);

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
