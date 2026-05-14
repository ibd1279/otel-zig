//! Basic Span Processor Implementation
//!
//! This module provides the BasicSpanProcessor implementation for processing spans
//! in the OpenTelemetry SDK. The BasicSpanProcessor immediately forwards each span
//! to the configured exporter without any batching or filtering.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md#span-processor

const std = @import("std");
const otel_api = @import("otel-api");
const sdk = struct {
    const trace = struct {
        const SpanData = @import("data.zig").SpanData;
    };
};

const RecordingSpan = @import("data.zig").RecordingSpan;
const SpanExporter = @import("exporter.zig").SpanExporter;
const Resource = @import("../resource/resource.zig").Resource;
const ProcessResult = @import("otel-api").common.ProcessResult;
const ExportResult = @import("otel-api").common.ExportResult;

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import the processor interface and bridge
const processor_zig = @import("processor.zig");
const SpanProcessor = processor_zig.SpanProcessor;
const BridgeSpanProcessor = processor_zig.BridgeSpanProcessor;

/// Convert ExportResult to ProcessResult
fn exportResultToProcessResult(result: ExportResult) ProcessResult {
    return switch (result) {
        .success => .success,
        .failure => .failure,
        .timeout => .timeout,
    };
}

/// Basic span processor implementation.
///
/// Implementation is a pass through to the exporter.
pub const BasicSpanProcessor = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        BasicSpanProcessor,
        SpanProcessor,
        void,
        spanProcessor,
        _initFn,
        setExporter,
    );
    pub fn _initFn(self: *BasicSpanProcessor, _: void, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, null);
    }

    allocator: std.mem.Allocator,
    exporter: ?SpanExporter,
    mutex: std.atomic.Mutex,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, exporter: ?SpanExporter) BasicSpanProcessor {
        return .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .unlocked,
            .is_shutdown = false,
        };
    }

    pub fn deinit(self: *BasicSpanProcessor) void {
        if (self.exporter) |exporter| {
            exporter.deinit();
            exporter.destroy();
        }
    }

    pub fn destroy(self: *BasicSpanProcessor) void {
        self.allocator.destroy(self);
    }

    pub fn setExporter(self: *BasicSpanProcessor, exporter: ?SpanExporter) !void {
        if (self.exporter) |old_exporter| {
            old_exporter.deinit();
            old_exporter.destroy();
        }
        self.exporter = exporter;
    }

    pub fn spanLimits(self: *const BasicSpanProcessor) otel_api.trace.Span.Limits {
        _ = self;
        return .default;
    }

    pub fn onEnd(self: *BasicSpanProcessor, span: sdk.trace.SpanData, resource: Resource) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return;
        }

        // Export single span immediately
        const spans = [_]sdk.trace.SpanData{span};

        if (self.exporter) |exporter| {
            const result = exporter.exportSpans(&spans, resource);
            if (result == .failure or result == .timeout) {
                error_handler.reportError(.{
                    .component = .processor,
                    .operation = "span_export",
                    .error_type = .network,
                    .message = "Failed to export span",
                    .context = span.name,
                });
            }
        }
    }

    pub fn forceFlush(self: *BasicSpanProcessor, timeout_ms: ?u64) otel_api.common.FlushResult {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = if (self.exporter) |*exporter| exporter.forceFlush(timeout_ms) else ExportResult.success;
        return result.asFlushResult();
    }

    pub fn shutdown(self: *BasicSpanProcessor, timeout_ms: ?u64) ProcessResult {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = if (self.exporter) |*exporter| exporter.shutdown(timeout_ms) else ExportResult.success;
        return result.asFlushResult().asProcessResult();
    }

    pub fn spanProcessor(self: *BasicSpanProcessor) SpanProcessor {
        return SpanProcessor{ .bridge = BridgeSpanProcessor.init(self) };
    }
};
