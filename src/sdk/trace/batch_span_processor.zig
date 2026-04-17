//! Batch Span Processor
//!
//! This module provides a span processor that batches spans and exports them
//! at regular intervals using a background thread. It uses POSIX threads
//! for cross-platform compatibility.
//!
//! The processor maintains a thread that wakes up at regular intervals to export
//! batched spans via the configured exporter. Spans are queued when they end
//! and exported in batches to improve performance.

const std = @import("std");
const otel_api = @import("otel-api");

fn milliTimestamp() i64 {
    var ts: std.posix.system.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
    const trace = struct {
        const SpanData = @import("data.zig").SpanData;
    };
};

const ProcessResult = otel_api.common.ProcessResult;
const ExportResult = otel_api.common.ExportResult;
const RecordingSpan = @import("data.zig").RecordingSpan;
const SpanExporter = @import("exporter.zig").SpanExporter;
const MockSpanExporter = @import("exporter.zig").MockSpanExporter;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import the processor interface and bridge
const processor_zig = @import("processor.zig");
const SpanProcessor = processor_zig.SpanProcessor;
const BridgeSpanProcessor = processor_zig.BridgeSpanProcessor;

/// Configuration for BatchSpanProcessor PipelineStep
pub const BatchConfig = struct {
    io: ?std.Io = null,
    export_interval_ms: ?u32 = null,
    max_queue_size: ?usize = null,
};

/// Batch span processor that exports spans at regular intervals
pub const BatchSpanProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        BatchSpanProcessor,
        SpanProcessor,
        BatchConfig,
        spanProcessor,
        _initFn,
        setExporter,
    );

    pub fn _initFn(self: *BatchSpanProcessor, config: BatchConfig, allocator: std.mem.Allocator) !void {
        const io = config.io orelse if (@import("builtin").is_test) std.testing.io else return error.IoRequired;
        self.* = init(io, allocator, null, config);
        try self.start();
    }

    io: std.Io,
    allocator: std.mem.Allocator,
    exporter: ?SpanExporter,
    mutex: std.Io.Mutex,
    condition: std.Io.Condition,
    is_shutdown: std.atomic.Value(bool),
    is_running: std.atomic.Value(bool),
    flush_in_progress: std.atomic.Value(bool),
    export_in_progress: std.atomic.Value(bool),
    flush_complete: std.Io.Condition,
    export_complete: std.Io.Condition,
    thread: ?std.Thread,
    export_interval_ms: u32,
    max_queue_size: usize,
    span_queue: std.ArrayList(struct { resource: sdk.Resource, data: sdk.trace.SpanData }),

    /// Initialize a new batch span processor
    /// export_interval_ms: How often to export spans (default: 5000ms = 5s)
    /// max_queue_size: Maximum spans to queue before dropping (default: 2048)
    ///
    /// Owner of the processor must destroy the memory.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        exporter: ?SpanExporter,
        config: BatchConfig,
    ) BatchSpanProcessor {
        return .{
            .io = io,
            .allocator = allocator,
            .exporter = exporter,
            .mutex = std.Io.Mutex.init,
            .condition = std.Io.Condition.init,
            .is_shutdown = .init(false),
            .is_running = .init(false),
            .flush_in_progress = .init(false),
            .export_in_progress = .init(false),
            .flush_complete = std.Io.Condition.init,
            .export_complete = std.Io.Condition.init,
            .thread = null,
            .export_interval_ms = config.export_interval_ms orelse 5000,
            .max_queue_size = config.max_queue_size orelse 2048,
            .span_queue = .empty,
        };
    }

    pub fn setExporter(self: *BatchSpanProcessor, exporter: ?SpanExporter) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (exporter) |exp| {
            self.exporter = exp;
        }
    }

    /// Start the background export thread
    pub fn start(self: *BatchSpanProcessor) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_running.load(.acquire) or self.thread != null) {
            return;
        }

        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, exportThreadFn, .{self});
    }

    /// Stop the background export thread and clean up resources
    pub fn deinit(self: *BatchSpanProcessor) void {
        // Signal shutdown; the export thread will observe this after its sleep expires
        self.is_shutdown.store(true, .release);
        self.is_running.store(false, .release);

        // Wait for thread to exit
        if (self.thread) |thread| {
            thread.join();
        }

        // Clean up remaining spans
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.span_queue.items) |span| {
            span.data.deinitOwned(self.allocator);
        }
        self.span_queue.deinit(self.allocator);

        // Clean up the exporter
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *BatchSpanProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn spanLimits(self: *BatchSpanProcessor) otel_api.trace.Span.Limits {
        _ = self;
        return .default;
    }

    /// Called when a span ends - adds span to batch queue
    pub fn onEnd(self: *BatchSpanProcessor, span: sdk.trace.SpanData, resource: sdk.Resource) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown.load(.acquire)) {
            return;
        }

        // Drop newest if queue is full
        if (self.span_queue.items.len >= self.max_queue_size) {
            return;
        }

        // Clone span for queuing (original will be deinitialized by caller)
        const cloned_span = sdk.trace.SpanData.initOwned(self.allocator, span) catch |err| {
            // Log error instead of silent drop
            error_handler.reportError(.{
                .component = .processor,
                .operation = "span_clone",
                .error_type = .resource_exhausted,
                .message = "Failed to clone span for batching",
                .context = span.name,
                .source_error = err,
            });
            return;
        };

        // Add cloned span to queue
        self.span_queue.append(self.allocator, .{ .resource = resource, .data = cloned_span }) catch |err| {
            cloned_span.deinitOwned(self.allocator);
            // Log queue overflow
            error_handler.reportError(.{
                .component = .processor,
                .operation = "queue_append",
                .error_type = .resource_exhausted,
                .message = "Span queue overflow, dropping span",
                .context = span.name,
                .source_error = err,
            });
            return;
        };
    }

    /// Force export all queued spans immediately
    pub fn forceFlush(self: *BatchSpanProcessor, timeout_ms: ?u64) otel_api.common.FlushResult {
        // Quick check without mutex
        if (self.is_shutdown.load(.acquire)) {
            return .failure;
        }

        const start_time = milliTimestamp();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Try to set flush_in_progress atomically
        const was_flushing = self.flush_in_progress.swap(true, .seq_cst);
        if (was_flushing) {
            // Another flush is in progress; loop on wait to guard against
            // spurious wakeups returning a false success.
            while (self.flush_in_progress.load(.acquire)) {
                const remaining_ms = if (timeout_ms) |ms|
                    ms -| @as(u64, @intCast(milliTimestamp() - start_time))
                else
                    null;

                if (remaining_ms == 0) {
                    return .timeout;
                }

                self.flush_complete.waitUncancelable(self.io, &self.mutex);
            }
            return .success;
        }

        defer {
            self.flush_in_progress.store(false, .release);
            self.flush_complete.broadcast(self.io);
        }

        // Wait for any export in progress
        while (self.export_in_progress.load(.acquire)) {
            const remaining_ms = if (timeout_ms) |ms|
                ms -| @as(u64, @intCast(milliTimestamp() - start_time))
            else
                null;

            if (remaining_ms == 0) {
                return .timeout;
            }

            self.export_complete.waitUncancelable(self.io, &self.mutex);
        }

        // Now do the export with atomic flag
        self.export_in_progress.store(true, .release);
        defer {
            self.export_in_progress.store(false, .release);
            self.export_complete.broadcast(self.io);
        }

        // Export spans (mutex is held)
        if (self.span_queue.items.len > 0) {
            const spans_to_export = self.span_queue.toOwnedSlice(self.allocator) catch |err| {
                error_handler.reportError(.{
                    .component = .processor,
                    .operation = "batch_export",
                    .error_type = .resource_exhausted,
                    .message = "Failed to export batch spans",
                    .source_error = err,
                });
                return .failure;
            };

            // Temporarily release mutex for export
            self.mutex.unlock(self.io);
            if (self.exporter) |exporter| {
                for (spans_to_export) |data_pair| {
                    _ = exporter.exportSpans(&.{data_pair.data}, data_pair.resource);
                }
            }
            for (spans_to_export) |data_pair| {
                data_pair.data.deinitOwned(self.allocator);
            }
            self.allocator.free(spans_to_export);
            self.mutex.lockUncancelable(self.io);
        }

        // Flush the exporter
        self.mutex.unlock(self.io);
        const flush_result = if (self.exporter) |exporter| exporter.forceFlush(timeout_ms) else ExportResult.success;
        self.mutex.lockUncancelable(self.io);

        return flush_result.asFlushResult();
    }

    /// Shutdown the processor
    pub fn shutdown(self: *BatchSpanProcessor, timeout_ms: ?u64) ProcessResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown.swap(true, .seq_cst)) {
            return .success;
        }

        self.is_running.store(false, .release);

        // Shutdown the exporter
        const result = if (self.exporter) |exporter| exporter.shutdown(timeout_ms) else ExportResult.success;
        return result.asFlushResult().asProcessResult();
    }

    /// Export all queued spans (must be called with mutex held)
    fn exportBatchLocked(self: *BatchSpanProcessor) void {
        if (self.is_shutdown.load(.acquire) or self.span_queue.items.len == 0) {
            return;
        }

        // Export all queued spans
        if (self.exporter) |exporter| {
            for (self.span_queue.items) |item| {
                _ = exporter.exportSpans(&.{item.data}, item.resource);
            }
        }

        // Clean up exported spans
        for (self.span_queue.items) |span| {
            span.data.deinitOwned(self.allocator);
        }
        self.span_queue.clearRetainingCapacity();
    }

    /// Export all queued spans (acquires mutex)
    fn exportBatch(self: *BatchSpanProcessor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.exportBatchLocked();
    }

    /// Background thread function that periodically exports spans
    fn exportThreadFn(self: *BatchSpanProcessor) void {
        while (true) {
            if (self.is_shutdown.load(.acquire)) break;

            // Sleep for the export interval
            const duration = std.Io.Duration.fromMilliseconds(@intCast(self.export_interval_ms));
            std.Io.sleep(self.io, duration, .awake) catch {};

            if (self.is_shutdown.load(.acquire)) break;

            // Skip if flush is in progress
            if (self.flush_in_progress.load(.acquire)) continue;

            // Try to acquire export lock
            if (self.export_in_progress.swap(true, .seq_cst)) continue;
            defer {
                self.export_in_progress.store(false, .release);
                self.export_complete.broadcast(self.io);
            }

            // Do the export
            self.exportBatch();
        }
    }

    pub fn spanProcessor(self: *BatchSpanProcessor) SpanProcessor {
        return SpanProcessor{ .bridge = BridgeSpanProcessor.init(self) };
    }
};

test "BatchSpanProcessor - basic initialization and cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(
        std.testing.io,
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 100, .max_queue_size = 5 },
    );
    defer {
        processor.deinit();
        processor.destroy();
    }

    // Test initial state
    try testing.expect(!processor.is_running.load(.unordered));
    try testing.expect(!processor.is_shutdown.load(.unordered));
    try testing.expectEqual(@as(usize, 0), processor.span_queue.items.len);
}

test "BatchSpanProcessor - span queuing and export" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(
        std.testing.io,
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 50, .max_queue_size = 10 },
    );

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = .init() }, .keep);
    defer provider.deinit();

    try provider.registerProcessor(processor.spanProcessor());
    const tracer = try provider.getTracerWithScope(.empty);

    // Create proper RecordingSpan for testing
    const span_context = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{1} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{1} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const recording_span_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, recording_span_ctx);
    var recording_span = try tracer.startSpan("test-span", .{}, recording_span_ctx);
    defer recording_span.deinit();

    // Test adding span to queue
    recording_span.end(null);

    processor.mutex.lockUncancelable(processor.io);
    try testing.expectEqual(@as(usize, 1), processor.span_queue.items.len);
    processor.mutex.unlock(processor.io);

    // Test force flush
    try testing.expectEqual(otel_api.common.FlushResult.success, processor.forceFlush(null));
    try testing.expectEqual(@as(usize, 1), mock_exporter.spanCount());

    processor.mutex.lockUncancelable(processor.io);
    try testing.expectEqual(@as(usize, 0), processor.span_queue.items.len);
    processor.mutex.unlock(processor.io);
}

test "BatchSpanProcessor - queue overflow drops newest" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(
        std.testing.io,
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 1000, .max_queue_size = 2 },
    );

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = .init() }, .keep);
    defer provider.deinit();

    try provider.registerProcessor(processor.spanProcessor());

    const tracer = try provider.getTracerWithScope(.empty);

    // Create proper RecordingSpans for testing
    const span_context1 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{1} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{1} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
    const span_context2 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{2} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{2} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
    const span_context3 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{3} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{3} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const span1_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context1);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span1_ctx);
    var span1 = try tracer.startSpan("test-span-1", .{}, span1_ctx);
    defer span1.deinit();

    const span2_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context2);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span2_ctx);
    var span2 = try tracer.startSpan("test-span-2", .{}, span2_ctx);
    defer span2.deinit();

    const span3_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context3);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span3_ctx);
    var span3 = try tracer.startSpan("test-span-3", .{}, span3_ctx);
    defer span3.deinit();

    // Fill queue to capacity
    span1.end(null);
    span2.end(null);

    processor.mutex.lockUncancelable(processor.io);
    try testing.expectEqual(@as(usize, 2), processor.span_queue.items.len);
    processor.mutex.unlock(processor.io);

    // This should be dropped (newest dropped policy)
    span3.end(null);

    processor.mutex.lockUncancelable(processor.io);
    try testing.expectEqual(@as(usize, 2), processor.span_queue.items.len); // Still 2
    processor.mutex.unlock(processor.io);
}

test "BatchSpanProcessor - shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = .init() }, .keep);
    defer provider.deinit();

    var processor: *BatchSpanProcessor = undefined;
    try @import("../common/pipeline.zig").buildPipeline(&provider).withCaptured(
        BatchSpanProcessor.PipelineStep.init(.{
            .export_interval_ms = 1000,
            .max_queue_size = 2,
        }),
        &processor,
    ).done();

    const tracer = try provider.getTracerWithScope(.empty);

    // Test shutdown
    try testing.expect(processor.is_shutdown.load(.monotonic) == false);
    try testing.expectEqual(ProcessResult.success, processor.shutdown(null));
    try testing.expect(processor.is_shutdown.load(.unordered));

    // Operations after shutdown should handle gracefully
    const span_context = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = [_]u8{1} ** 16 },
        .span_id = otel_api.common.SpanId{ .bytes = [_]u8{1} ** 8 },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };

    const test_span_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, test_span_ctx);
    var test_span = try tracer.startSpan("test-span", .{}, test_span_ctx);
    defer test_span.deinit();

    test_span.end(null); // Should be handled gracefully after shutdown

    try testing.expectEqual(otel_api.common.FlushResult.failure, processor.forceFlush(null));
}
