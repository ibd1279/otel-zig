//! Simple Log Record Processor Implementation
//!
//! This module provides the SimpleLogRecordProcessor implementation for processing log records
//! in the OpenTelemetry SDK. The SimpleLogRecordProcessor immediately forwards each log record
//! to the configured exporter without any batching or filtering.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md#logrecordprocessor

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
    const LogRecord = @import("log_record.zig").LogRecord;
    const LogRecordExporter = @import("exporter.zig").LogRecordExporter;
    const LogRecordProcessor = @import("processor.zig").LogRecordProcessor;
    const BridgeLogRecordProcessor = @import("processor.zig").BridgeLogRecordProcessor;
};

/// Simple log record processor implementation.
///
/// Implementation is a pass through to the exporter.
pub const SimpleLogRecordProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        SimpleLogRecordProcessor,
        sdk.LogRecordProcessor,
        void,
        logProcessor,
        _initFn,
        setExporter,
    );
    pub fn _initFn(self: *SimpleLogRecordProcessor, _: void, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, null);
    }

    allocator: std.mem.Allocator,
    exporter: ?sdk.LogRecordExporter,
    mutex: std.atomic.Mutex,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, exporter: ?sdk.LogRecordExporter) SimpleLogRecordProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .unlocked,
            .is_shutdown = false,
        };
    }

    pub fn deinit(self: *SimpleLogRecordProcessor) void {
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *SimpleLogRecordProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn setExporter(self: *SimpleLogRecordProcessor, exporter: ?sdk.LogRecordExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    pub fn onEmit(self: *SimpleLogRecordProcessor, record: sdk.LogRecord, ctx: []const api.ContextKeyValue, resource: sdk.Resource) void {
        _ = ctx;

        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return;
        }

        // Export single record immediately
        const records = [_]sdk.LogRecord{record};

        if (self.exporter) |exporter| {
            const result = exporter.exportRecords(&records, resource);
            if (result != .success) {
                const message_body = if (record.body) |body| body.string else "(no message)";
                api.common.reportError(.{
                    .component = .processor,
                    .operation = "log_export",
                    .error_type = .network,
                    .message = "Failed to export log record",
                    .context = message_body,
                });
            }
        }
    }

    pub fn forceFlush(self: *SimpleLogRecordProcessor, timeout_ms: ?u64) api.common.FlushResult {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = if (self.exporter) |*exporter| exporter.forceFlush(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *SimpleLogRecordProcessor, timeout_ms: ?u64) api.common.ProcessResult {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else .success;
        return if (result == .success) .success else .failure;
    }

    pub fn logProcessor(self: *SimpleLogRecordProcessor) sdk.LogRecordProcessor {
        return sdk.LogRecordProcessor{ .bridge = sdk.BridgeLogRecordProcessor.init(self) };
    }
};
