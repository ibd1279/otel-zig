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

const QueuedSpan = struct { resource: sdk.Resource, data: sdk.trace.SpanData };

/// Configuration for BatchSpanProcessor PipelineStep
pub const BatchConfig = struct {
    io: ?std.Io = null,
    export_interval_ms: ?u32 = null,
    max_queue_size: ?usize = null,
    max_export_batch_size: ?usize = null,
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
    max_export_batch_size: usize,
    span_queue: std.ArrayList(QueuedSpan),

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
            .max_export_batch_size = @max(1, @min(config.max_export_batch_size orelse 512, config.max_queue_size orelse 2048)),
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
        self.exporter = exporter;
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
        // Fast pre-check without the lock; a racing shutdown is re-checked below.
        if (self.is_shutdown.load(.acquire)) {
            return;
        }

        // Clone the span BEFORE taking the lock. initOwned is the expensive part
        // of onEnd: a deep heap copy of the span name and every attribute (which
        // for DB/HTTP instrumentation includes large SQL/URL strings). Cloning
        // under the mutex serializes every concurrent onEnd — and with many
        // request threads on few cores, a thread preempted mid-copy stalls all
        // the others. That lock convoy turns a flood of sub-millisecond spans
        // into multi-second tail latency (observed downstream: 14 spans/request
        // × 24 concurrent requests → seconds of inter-span gaps). Cloning first
        // keeps the critical section to a capacity check plus a pointer append.
        const cloned_span = sdk.trace.SpanData.initOwned(self.allocator, span) catch |err| {
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

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Re-check under the lock: shutdown may have raced us, and the queue may
        // have filled while we were cloning. Free the clone in either case so it
        // is not leaked (the caller still owns and deinits the original `span`).
        if (self.is_shutdown.load(.acquire) or self.span_queue.items.len >= self.max_queue_size) {
            cloned_span.deinitOwned(self.allocator);
            return;
        }

        self.span_queue.append(self.allocator, .{ .resource = resource, .data = cloned_span }) catch |err| {
            cloned_span.deinitOwned(self.allocator);
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
        // Wake the background thread early: a threshold-sized batch has queued
        // up, so it should export before the next interval tick. Reuses the
        // generic wake event (also used for shutdown) — the thread re-checks
        // is_shutdown after every wait.
        if (self.span_queue.items.len >= self.max_export_batch_size) self.shutdown_signal.set(self.io);
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
            // Chunked export (max_export_batch_size per call) via the same
            // helper the background thread uses, so the exporter sees
            // identical batching regardless of who drains the queue.
            // Flush still runs below; a failed batch export surfaces there
            // or as an error report — forceFlush's contract is the exporter's
            // own result, matching the pre-chunking behavior.
            _ = self.exportOwned(spans_to_export);
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

    /// Export all queued spans, releasing the mutex during HTTP export.
    /// Must be called with mutex held. Mutex is held again on return.
    fn exportBatchUnlocked(self: *BatchSpanProcessor) void {
        if (self.is_shutdown.load(.acquire) or self.span_queue.items.len == 0) {
            return;
        }

        // Drain queue under the lock
        const spans_to_export = self.span_queue.toOwnedSlice(self.allocator) catch return;

        // Release mutex during export — HTTP calls can take seconds
        self.mutex.unlock(self.io);

        _ = self.exportOwned(spans_to_export);

        // Re-acquire mutex before returning
        self.mutex.lockUncancelable(self.io);
    }

    /// Export all queued spans (acquires mutex)
    fn exportBatch(self: *BatchSpanProcessor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.exportBatchUnlocked();
    }

    fn exportOwned(self: *BatchSpanProcessor, items: []QueuedSpan) ExportResult {
        defer {
            for (items) |item| item.data.deinitOwned(self.allocator);
            self.allocator.free(items);
        }
        const exporter = self.exporter orelse return .success;
        const batch = self.allocator.alloc(sdk.trace.SpanData, @min(items.len, self.max_export_batch_size)) catch return .failure;
        defer self.allocator.free(batch);
        var result: ExportResult = .success;
        var offset: usize = 0;
        while (offset < items.len) {
            const count = @min(batch.len, items.len - offset);
            for (items[offset .. offset + count], 0..) |item, i| batch[i] = item.data;
            const current = exporter.exportSpans(batch[0..count], items[offset].resource);
            if (!current.isSuccess()) result = current;
            offset += count;
        }
        return result;
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

            // Do the export — exportBatch drains the queue under the lock and
            // releases the mutex during HTTP export (same pattern as forceFlush).
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
    const tracer = provider.getTracerWithScope(.empty);

    // Create proper RecordingSpan for testing
    const span_context = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = @splat(1) },
        .span_id = otel_api.common.SpanId{ .bytes = @splat(1) },
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

test "BatchSpanProcessor exports bounded batches" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);
    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(std.testing.io, allocator, mock_exporter.spanExporter(), .{
        .export_interval_ms = 1_000_000,
        .max_queue_size = 10,
        .max_export_batch_size = 2,
    });

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = try @import("id_generator.zig").RandomIdGenerator.init(std.testing.io) }, .keep);
    defer provider.deinit();
    try provider.registerProcessor(processor.spanProcessor());
    const tracer = provider.getTracerWithScope(.empty);

    for (0..5) |_| {
        var span = tracer.startSpan("batched-span", .{}, &.{});
        span.end(null);
        span.deinit();
    }
    try testing.expectEqual(otel_api.common.FlushResult.success, processor.forceFlush(null));
    try testing.expectEqual(@as(usize, 5), mock_exporter.spanCount());
    try testing.expectEqual(@as(usize, 3), mock_exporter.exportCallCount());
}

test "BatchSpanProcessor threshold wakes exporter before schedule" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);
    const processor = try allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(std.testing.io, allocator, mock_exporter.spanExporter(), .{
        .export_interval_ms = 60_000,
        .max_queue_size = 10,
        .max_export_batch_size = 2,
    });

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = try @import("id_generator.zig").RandomIdGenerator.init(std.testing.io) }, .keep);
    defer provider.deinit();
    try provider.registerProcessor(processor.spanProcessor());
    try processor.start();
    const tracer = provider.getTracerWithScope(.empty);

    for (0..2) |_| {
        var span = tracer.startSpan("threshold-span", .{}, &.{});
        span.end(null);
        span.deinit();
    }
    const deadline = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds + 500 * std.time.ns_per_ms;
    while (mock_exporter.exportCallCount() == 0 and std.Io.Timestamp.now(std.testing.io, .real).nanoseconds < deadline) {
        std.testing.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real) catch {};
    }
    try testing.expect(mock_exporter.exportCallCount() > 0);
    try testing.expectEqual(otel_api.common.FlushResult.success, processor.forceFlush(1000));
    try testing.expectEqual(@as(usize, 2), mock_exporter.spanCount());
}

test "BatchSpanProcessor force flush timeout bounds an in-progress export wait" {
    const testing = std.testing;
    const processor = try testing.allocator.create(BatchSpanProcessor);
    processor.* = BatchSpanProcessor.init(std.testing.io, testing.allocator, null, .{});
    defer {
        processor.export_in_progress.store(false, .release);
        processor.export_complete.broadcast(std.testing.io);
        processor.deinit();
        processor.destroy();
    }

    processor.export_in_progress.store(true, .release);
    const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    try testing.expectEqual(otel_api.common.FlushResult.timeout, processor.forceFlush(30));
    const elapsed = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    try testing.expect(elapsed >= 20 * std.time.ns_per_ms);
    try testing.expect(elapsed < 200 * std.time.ns_per_ms);
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

    const tracer = provider.getTracerWithScope(.empty);

    // Create proper RecordingSpans for testing
    const span_context1 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = @splat(1) },
        .span_id = otel_api.common.SpanId{ .bytes = @splat(1) },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
    const span_context2 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = @splat(2) },
        .span_id = otel_api.common.SpanId{ .bytes = @splat(2) },
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
    const span_context3 = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = @splat(3) },
        .span_id = otel_api.common.SpanId{ .bytes = @splat(3) },
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

    const tracer = provider.getTracerWithScope(.empty);

    // Test shutdown
    try testing.expect(processor.is_shutdown.load(.monotonic) == false);
    try testing.expectEqual(ProcessResult.success, processor.shutdown(null));
    try testing.expect(processor.is_shutdown.load(.unordered));

    // Operations after shutdown should handle gracefully
    const span_context = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = @splat(1) },
        .span_id = otel_api.common.SpanId{ .bytes = @splat(1) },
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
    const tracer = provider.getTracerWithScope(.empty);

    // Queue 3 spans via onEnd().
    const make_ctx = struct {
        fn call(byte: u8) otel_api.trace.Span.Context {
            return .{
                .trace_id = .{ .bytes = @splat(byte) },
                .span_id = .{ .bytes = @splat(byte) },
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

test "BatchSpanProcessor - concurrent onEnd from many threads queues every span" {
    // Regression for the onEnd lock convoy: many threads end spans at once, so
    // onEnd's clone-then-lock path runs fully concurrently. Asserts every span
    // is queued exactly once (no lost or double-counted spans) and — via the
    // testing allocator — that no clone leaks on any path.
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock_error_handler = otel_api.common.MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    const mock_exporter = try allocator.create(MockSpanExporter);
    mock_exporter.* = MockSpanExporter.init(allocator);

    const processor = try allocator.create(BatchSpanProcessor);
    // High interval + init() without start() means the export thread never
    // drains; the queue must hold every span. Queue sized well above the total
    // so none are dropped.
    processor.* = BatchSpanProcessor.init(
        std.testing.io,
        allocator,
        mock_exporter.spanExporter(),
        .{ .export_interval_ms = 1_000_000, .max_queue_size = 4096 },
    );
    // Deliberately not calling processor.start(): no background drain.

    const resource = try sdk.Resource.initOwned(allocator, .{ .attributes = &.{} });
    var provider = @import("tracer_provider.zig").TracerProvider.init(allocator, std.testing.io, resource, .{ .random = try @import("id_generator.zig").RandomIdGenerator.init(std.testing.io) }, .keep);
    defer provider.deinit();
    try provider.registerProcessor(processor.spanProcessor());

    const TracerProvider = @import("tracer_provider.zig").TracerProvider;
    const N_THREADS = 8;
    const SPANS_PER = 25;

    const Worker = struct {
        fn run(prov: *TracerProvider, alloc: std.mem.Allocator, ok: *std.atomic.Value(u32)) void {
            const tracer = prov.getTracerWithScope(.empty);
            const sc = otel_api.trace.Span.Context{
                .trace_id = otel_api.common.TraceId{ .bytes = @splat(7) },
                .span_id = otel_api.common.SpanId{ .bytes = @splat(7) },
                .trace_flags = 0,
                .trace_state = null,
                .is_remote = false,
            };
            var i: usize = 0;
            while (i < SPANS_PER) : (i += 1) {
                const ctx = otel_api.trace.trace_context.withActiveSpanContext(alloc, &.{}, sc) catch return;
                defer otel_api.ContextKeyValue.deinitOwnedSlice(alloc, ctx);
                var span = tracer.startSpan("concurrent-span", .{}, ctx);
                span.end(null); // calls onEnd on this thread
                span.deinit();
            }
            _ = ok.fetchAdd(1, .monotonic);
        }
    };

    var ok = std.atomic.Value(u32).init(0);
    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &provider, allocator, &ok });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, N_THREADS), ok.load(.monotonic));
    processor.mutex.lockUncancelable(std.testing.io);
    defer processor.mutex.unlock(std.testing.io);
    try testing.expectEqual(@as(usize, N_THREADS * SPANS_PER), processor.span_queue.items.len);
}
