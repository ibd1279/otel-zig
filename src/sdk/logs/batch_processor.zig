//! Batch Log Record Processor Implementation
//!
//! This module provides the BatchLogRecordProcessor implementation for processing log records
//! in the OpenTelemetry SDK. The BatchLogRecordProcessor collects log records and exports them
//! in batches at regular intervals using a background thread.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#logrecordprocessor

const std = @import("std");
const api = @import("otel-api");

fn milliTimestamp() i64 {
    var ts: std.posix.system.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
    const LogRecord = @import("log_record.zig").LogRecord;
    const LogRecordExporter = @import("exporter.zig").LogRecordExporter;
    const LogRecordProcessor = @import("processor.zig").LogRecordProcessor;
    const BridgeLogRecordProcessor = @import("processor.zig").BridgeLogRecordProcessor;
};

/// Configuration for BatchLogRecordProcessor PipelineStep
pub const BatchConfig = struct {
    export_interval_ms: ?u32 = null,
    max_queue_size: ?usize = null,
};

/// Batch log record processor that exports log records at regular intervals
pub const BatchLogRecordProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        BatchLogRecordProcessor,
        sdk.LogRecordProcessor,
        BatchConfig,
        logProcessor,
        _initFn,
        setExporter,
    );

    pub fn _initFn(self: *BatchLogRecordProcessor, config: BatchConfig, allocator: std.mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .exporter = sdk.LogRecordExporter{ .noop = {} },
            .mutex = .{},
            .condition = .{},
            .is_shutdown = .init(false),
            .is_running = .init(false),
            .flush_in_progress = .init(false),
            .export_in_progress = .init(false),
            .flush_complete = .{},
            .export_complete = .{},
            .thread = null,
            .export_interval_ms = config.export_interval_ms orelse 5000,
            .max_queue_size = config.max_queue_size orelse 2048,
            .log_queue = .empty,
        };
        try self.start();
    }

    allocator: std.mem.Allocator,
    exporter: sdk.LogRecordExporter,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    is_shutdown: std.atomic.Value(bool),
    is_running: std.atomic.Value(bool),
    flush_in_progress: std.atomic.Value(bool),
    export_in_progress: std.atomic.Value(bool),
    flush_complete: std.Thread.Condition,
    export_complete: std.Thread.Condition,
    thread: ?std.Thread,
    export_interval_ms: u32,
    max_queue_size: usize,
    log_queue: std.ArrayList(sdk.LogRecord),

    /// Initialize a new batch log record processor
    /// export_interval_ms: How often to export log records (default: 5000ms = 5s)
    /// max_queue_size: Maximum log records to queue before dropping (default: 2048)
    ///
    /// Owner of the processor must destroy the memory.
    pub fn init(
        allocator: std.mem.Allocator,
        exporter: sdk.LogRecordExporter,
        export_interval_ms: ?u32,
        max_queue_size: ?usize,
    ) !*BatchLogRecordProcessor {
        const self = try allocator.create(BatchLogRecordProcessor);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .{},
            .condition = .{},
            .is_shutdown = .init(false),
            .is_running = .init(false),
            .flush_in_progress = .init(false),
            .export_in_progress = .init(false),
            .flush_complete = .{},
            .export_complete = .{},
            .thread = null,
            .export_interval_ms = export_interval_ms orelse 5000,
            .max_queue_size = max_queue_size orelse 2048,
            .log_queue = .empty,
        };

        return self;
    }

    pub fn setExporter(self: *BatchLogRecordProcessor, exporter: ?sdk.LogRecordExporter) !void {
        self.exporter.deinit();
        self.exporter.destroy();
        self.exporter = exporter orelse sdk.LogRecordExporter{ .noop = {} };
    }

    /// Start the background export thread
    pub fn start(self: *BatchLogRecordProcessor) !void {
        if (self.is_running.swap(true, .seq_cst)) {
            return; // Already running
        }

        self.thread = try std.Thread.spawn(.{}, exportThreadFn, .{self});
    }

    /// Stop and cleanup the processor
    pub fn deinit(self: *BatchLogRecordProcessor) void {
        // Signal shutdown
        self.is_shutdown.store(true, .release);

        // Wake up the export thread
        self.mutex.lock();
        self.condition.broadcast();
        self.mutex.unlock();

        // Wait for thread to finish
        if (self.thread) |thread| {
            thread.join();
        }

        // Export any remaining log records
        self.mutex.lock();
        _ = self.exportBatchLocked();

        // Clean up remaining log records
        for (self.log_queue.items) |record| {
            record.deinitOwned(self.allocator);
        }
        self.log_queue.deinit(self.allocator);
        self.mutex.unlock();

        // Clean up exporter
        self.exporter.deinit();
        self.exporter.destroy();
    }

    pub fn destroy(self: *BatchLogRecordProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn onEmit(self: *BatchLogRecordProcessor, record: sdk.LogRecord, ctx: []const api.ContextKeyValue, resource: sdk.Resource) void {
        _ = ctx;
        _ = resource;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) {
            return;
        }

        // Drop newest if queue is full
        if (self.log_queue.items.len >= self.max_queue_size) {
            return;
        }

        // Clone log record for queuing
        var owned_record = sdk.LogRecord.initOwned(self.allocator, record) catch |err| {
            const message_body = if (record.body) |body| switch (body) {
                .string => |s| s,
                else => "(complex body)",
            } else "(no body)";

            api.common.reportError(.{
                .component = .processor,
                .operation = "log_clone",
                .error_type = .resource_exhausted,
                .message = "Failed to clone log record for batching",
                .context = message_body,
                .source_error = err,
            });
            return;
        };

        // Add cloned log record to queue
        self.log_queue.append(self.allocator, owned_record) catch |err| {
            owned_record.deinitOwned(self.allocator);

            const message_body = if (record.body) |body| switch (body) {
                .string => |s| s,
                else => "(complex body)",
            } else "(no body)";

            api.common.reportError(.{
                .component = .processor,
                .operation = "queue_append",
                .error_type = .resource_exhausted,
                .message = "Log record queue overflow, dropping record",
                .context = message_body,
                .source_error = err,
            });
            return;
        };
    }

    /// Force export all queued log records immediately
    pub fn forceFlush(self: *BatchLogRecordProcessor, timeout_ms: ?u64) api.common.FlushResult {
        // Quick check without mutex
        if (self.is_shutdown.load(.acquire)) {
            return .failure;
        }

        const start_time = milliTimestamp();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to set flush_in_progress atomically
        const was_flushing = self.flush_in_progress.swap(true, .seq_cst);
        if (was_flushing) {
            // Another flush is in progress, wait for it
            const remaining_ms = if (timeout_ms) |ms|
                ms -| @as(u64, @intCast(milliTimestamp() - start_time))
            else
                null;

            if (remaining_ms == 0) {
                return .timeout;
            }

            if (remaining_ms) |ms| {
                self.flush_complete.timedWait(&self.mutex, ms * std.time.ns_per_ms) catch {
                    return .timeout;
                };
            } else {
                self.flush_complete.wait(&self.mutex);
            }
            return .success;
        }

        defer {
            self.flush_in_progress.store(false, .release);
            self.flush_complete.broadcast();
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

            if (remaining_ms) |ms| {
                self.export_complete.timedWait(&self.mutex, ms * std.time.ns_per_ms) catch {
                    return .timeout;
                };
            } else {
                self.export_complete.wait(&self.mutex);
            }
        }

        // Now do the export with atomic flag
        self.export_in_progress.store(true, .release);
        defer {
            self.export_in_progress.store(false, .release);
            self.export_complete.broadcast();
        }

        // Export log records (mutex is held)
        if (self.log_queue.items.len > 0) {
            const result = self.exportBatchLocked();
            if (result != .success) {
                return .failure;
            }
        }

        // Flush the exporter
        self.mutex.unlock();
        const flush_result = self.exporter.forceFlush(timeout_ms);
        self.mutex.lock();

        return flush_result.asFlushResult();
    }

    pub fn shutdown(self: *BatchLogRecordProcessor, timeout_ms: ?u64) api.common.ProcessResult {
        // Signal shutdown
        self.is_shutdown.store(true, .release);

        // Force flush remaining records
        const result = self.forceFlush(timeout_ms);

        // Shutdown the exporter
        const shutdown_result = self.exporter.shutdown(timeout_ms);

        return if (result == .success and shutdown_result == .success)
            .success
        else
            .failure;
    }

    /// Export a batch of log records (must be called with mutex held)
    fn exportBatchLocked(self: *BatchLogRecordProcessor) api.common.ExportResult {
        if (self.log_queue.items.len == 0) {
            return .success;
        }

        // Export log records directly from queue
        // Temporarily release mutex for export
        self.mutex.unlock();
        const result = self.exporter.exportRecords(self.log_queue.items, @import("../resource/resource.zig").Resource.empty);
        self.mutex.lock();

        // Clean up exported records
        for (self.log_queue.items) |record| {
            record.deinitOwned(self.allocator);
        }
        self.log_queue.clearRetainingCapacity();

        return result;
    }

    /// Background thread function for periodic exports
    fn exportThreadFn(self: *BatchLogRecordProcessor) void {
        while (true) {
            // Fast path check without mutex
            if (self.is_shutdown.load(.acquire)) {
                break;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            // Double-check under mutex
            if (self.is_shutdown.load(.acquire)) {
                break;
            }

            // Calculate wait time in nanoseconds
            const wait_ns = @as(u64, self.export_interval_ms) * std.time.ns_per_ms;

            // Wait for the specified interval or until signaled
            self.condition.timedWait(&self.mutex, wait_ns) catch {
                // Timeout - normal export cycle
            };

            // Skip if flush is in progress
            if (self.flush_in_progress.load(.acquire)) {
                continue;
            }

            // Try to acquire export lock
            if (self.export_in_progress.swap(true, .seq_cst)) {
                // Already exporting, skip this cycle
                continue;
            }

            defer {
                self.export_in_progress.store(false, .release);
                self.export_complete.broadcast();
            }

            // Do the export
            _ = self.exportBatchLocked();
        }
    }

    pub fn logProcessor(self: *BatchLogRecordProcessor) sdk.LogRecordProcessor {
        return sdk.LogRecordProcessor{ .bridge = sdk.BridgeLogRecordProcessor.init(self) };
    }
};
