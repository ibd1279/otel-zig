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
    /// Signaled in deinit() to wake the background thread immediately
    /// rather than waiting up to export_interval_ms for the sleep to expire.
    shutdown_signal: std.Io.Event,
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
            .shutdown_signal = .unset,
            .export_interval_ms = config.export_interval_ms orelse 5000,
            .max_queue_size = config.max_queue_size orelse 2048,
            .span_queue = .empty,
        };
    }

    pub fn setExporter(self: *BatchSpanProcessor, exporter: ?SpanExporter) !void {
        // Drain all queued spans and wait for in-flight export to complete
        // before replacing the exporter. forceFlush acquires self.mutex
        // internally, so it must be called before we acquire it below.
        _ = self.forceFlush(null);

        self.mutex.lockUncancelable(self.io);
        const old_exporter = self.exporter;
        if (exporter) |exp| {
            self.exporter = exp;
        }
        self.mutex.unlock(self.io);

        if (old_exporter) |old| {
            old.deinit();
            old.destroy();
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
        // Signal shutdown and wake the background thread immediately
        // (without the signal it would sleep for up to export_interval_ms).
        self.is_shutdown.store(true, .release);
        self.is_running.store(false, .release);
        self.shutdown_signal.set(self.io);

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
        return @import("../common/batch_flush.zig").performForceFlush(
            BatchSpanProcessor,
            self,
            timeout_ms,
            exportBatchAndFlushExporterLocked,
        );
    }

    /// Export queued spans and flush the exporter. Called with self.mutex held.
    fn exportBatchAndFlushExporterLocked(self: *BatchSpanProcessor, timeout_ms: ?u64) otel_api.common.FlushResult {
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

            // Sleep for the export interval or until signaled for shutdown.
            const raw = std.Io.Duration.fromMilliseconds(@intCast(self.export_interval_ms));
            const timeout = std.Io.Timeout{ .duration = .{ .raw = raw, .clock = .awake } };
            self.shutdown_signal.waitTimeout(self.io, timeout) catch {};
            self.shutdown_signal.reset();

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
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = try @import("id_generator.zig").RandomIdGenerator.init(std.testing.io) }, .keep);
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
    var recording_span = tracer.startSpan("test-span", .{}, recording_span_ctx);
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
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = try @import("id_generator.zig").RandomIdGenerator.init(std.testing.io) }, .keep);
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
    var span1 = tracer.startSpan("test-span-1", .{}, span1_ctx);
    defer span1.deinit();

    const span2_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context2);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span2_ctx);
    var span2 = tracer.startSpan("test-span-2", .{}, span2_ctx);
    defer span2.deinit();

    const span3_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, span_context3);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, span3_ctx);
    var span3 = tracer.startSpan("test-span-3", .{}, span3_ctx);
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
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = try @import("id_generator.zig").RandomIdGenerator.init(std.testing.io) }, .keep);
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
    var test_span = tracer.startSpan("test-span", .{}, test_span_ctx);
    defer test_span.deinit();

    test_span.end(null); // Should be handled gracefully after shutdown

    try testing.expectEqual(otel_api.common.FlushResult.failure, processor.forceFlush(null));
}

test "BatchSpanProcessor - setExporter drains and frees old exporter" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    // Create the first mock exporter on the heap so we can inspect it after
    // setExporter calls deinit() and destroy() on it.
    const mock_exporter_1 = try allocator.create(MockSpanExporter);
    mock_exporter_1.* = MockSpanExporter.init(allocator);

    // Create the processor with mock_exporter_1 as the initial exporter.
    // Ownership of processor transfers to provider via registerProcessor below.
    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(
        std.testing.io,
        allocator,
        mock_exporter_1.spanExporter(),
        .{ .export_interval_ms = 60_000, .max_queue_size = 10 },
    );

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = try @import("id_generator.zig").RandomIdGenerator.init(std.testing.io) }, .keep);
    defer provider.deinit();

    try provider.registerProcessor(processor.spanProcessor());
    const tracer = try provider.getTracerWithScope(.empty);

    // Queue 3 spans via onEnd().
    const make_ctx = struct {
        fn call(byte: u8) otel_api.trace.Span.Context {
            return .{
                .trace_id = .{ .bytes = [_]u8{byte} ** 16 },
                .span_id = .{ .bytes = [_]u8{byte} ** 8 },
                .trace_flags = 0,
                .trace_state = null,
                .is_remote = false,
            };
        }
    }.call;

    const ctx1 = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, make_ctx(1));
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, ctx1);
    var s1 = tracer.startSpan("span-1", .{}, ctx1);
    defer s1.deinit();
    s1.end(null);

    const ctx2 = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, make_ctx(2));
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, ctx2);
    var s2 = tracer.startSpan("span-2", .{}, ctx2);
    defer s2.deinit();
    s2.end(null);

    const ctx3 = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, make_ctx(3));
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, ctx3);
    var s3 = tracer.startSpan("span-3", .{}, ctx3);
    defer s3.deinit();
    s3.end(null);

    // Verify 3 spans are queued.
    processor.mutex.lockUncancelable(processor.io);
    try testing.expectEqual(@as(usize, 3), processor.span_queue.items.len);
    processor.mutex.unlock(processor.io);

    // Stack bool written by mock_exporter_1.deinit() via deinit_notify.
    // This lives on the stack so it remains valid after destroy() frees the heap allocation.
    var exporter_1_deinit_called = false;
    mock_exporter_1.deinit_notify = &exporter_1_deinit_called;

    // Create the second mock exporter. Ownership transfers to the processor via setExporter;
    // processor.deinit() (via the outer defer) will call deinit()+destroy() on it.
    const mock_exporter_2 = try allocator.create(MockSpanExporter);
    mock_exporter_2.* = MockSpanExporter.init(allocator);

    try processor.setExporter(mock_exporter_2.spanExporter());

    // mock_exporter_1.deinit() must have been called; the flag is on our stack so no UB.
    try testing.expect(exporter_1_deinit_called);

    // The queue must be empty: setExporter drained via forceFlush before swapping.
    processor.mutex.lockUncancelable(processor.io);
    try testing.expectEqual(@as(usize, 0), processor.span_queue.items.len);
    processor.mutex.unlock(processor.io);

    // Queue 1 more span and flush — it must arrive at mock_exporter_2, not the old one.
    const ctx4 = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, make_ctx(4));
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, ctx4);
    var s4 = tracer.startSpan("span-4", .{}, ctx4);
    defer s4.deinit();
    s4.end(null);

    try testing.expectEqual(otel_api.common.FlushResult.success, processor.forceFlush(null));
    try testing.expectEqual(@as(usize, 1), mock_exporter_2.spanCount());
}
