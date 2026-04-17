//! OpenTelemetry Span Processor Interface
//!
//! This module defines the SpanProcessor interface for processing spans
//! in the OpenTelemetry SDK. Processors receive spans when they end
//! and are responsible for batching, filtering, and forwarding them to exporters.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md#span-processor

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
const BridgeSpanExporter = @import("exporter.zig").BridgeSpanExporter;

/// SpanProcessor interface using tagged union for polymorphism
pub const SpanProcessor = union(enum) {
    noop: void,
    simple: *SimpleSpanProcessor,
    bridge: BridgeSpanProcessor,

    /// Exposes the limits that the processor will support.
    pub fn spanLimits(self: *const SpanProcessor) otel_api.trace.Span.Limits {
        return switch (self.*) {
            .noop => .default,
            .simple => |processor| processor.spanLimits(),
            .bridge => |processor| processor.spanLimitsFn(processor.processor_ptr),
        };
    }

    /// Called when a span ends
    pub fn onEnd(self: *SpanProcessor, span: sdk.trace.SpanData, resource: sdk.Resource) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.onEnd(span, resource),
            .bridge => |processor| processor.onEndFn(processor.processor_ptr, span, resource),
        }
    }

    /// Force flush any buffered spans
    pub fn forceFlush(self: *SpanProcessor, timeout_ms: ?u64) otel_api.common.FlushResult {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.forceFlush(timeout_ms),
            .bridge => |processor| processor.forceFlushFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Shutdown the processor
    pub fn shutdown(self: *SpanProcessor, timeout_ms: ?u64) ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .simple => |processor| processor.shutdown(timeout_ms),
            .bridge => |processor| processor.shutdownFn(processor.processor_ptr, timeout_ms),
        };
    }

    /// Clean up processor resources
    pub fn deinit(self: *const SpanProcessor) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.deinit(),
            .bridge => |processor| processor.deinitFn(processor.processor_ptr),
        }
    }

    /// Destroy processor memory
    pub fn destroy(self: *const SpanProcessor) void {
        switch (self.*) {
            .noop => {},
            .simple => |processor| processor.destroy(),
            .bridge => |processor| processor.destroyFn(processor.processor_ptr),
        }
    }
};

/// Simple span processor implementation.
///
/// Implementation is a pass through to the exporter.
pub const SimpleSpanProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    mutex: std.atomic.Mutex,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, exporter: SpanExporter) !*SimpleSpanProcessor {
        const self = try allocator.create(SimpleSpanProcessor);
        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = .unlocked,
            .is_shutdown = false,
        };
        return self;
    }

    pub fn deinit(self: *SimpleSpanProcessor) void {
        self.exporter.deinit();
    }

    pub fn destroy(self: *SimpleSpanProcessor) void {
        self.allocator.destroy(self);
    }

    pub inline fn spanLimits(self: *SimpleSpanProcessor) otel_api.trace.Span.Limits {
        _ = self;
        return .default;
    }

    pub inline fn onEnd(self: *SimpleSpanProcessor, span: sdk.trace.SpanData, resource: sdk.Resource) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return;
        }

        // Export single span immediately
        const spans = [_]sdk.trace.SpanData{span};
        _ = self.exporter.exportSpans(&spans, resource);
    }

    pub inline fn forceFlush(self: *SimpleSpanProcessor, timeout_ms: ?u64) otel_api.common.FlushResult {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .failure;
        }

        // Flush the exporter
        const result = self.exporter.forceFlush(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn shutdown(self: *SimpleSpanProcessor, timeout_ms: ?u64) ProcessResult {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;

        // Shutdown the exporter
        const result = self.exporter.shutdown(timeout_ms);
        return if (result == .success) .success else .failure;
    }

    pub fn spanProcessor(self: *SimpleSpanProcessor) SpanProcessor {
        return SpanProcessor{ .simple = self };
    }
};

/// Interface for bridging to a more complex processor.
pub const BridgeSpanProcessor = struct {
    processor_ptr: *anyopaque,
    spanLimitsFn: *const fn (processor_ptr: *anyopaque) otel_api.trace.Span.Limits,
    onEndFn: *const fn (processor_ptr: *anyopaque, span: sdk.trace.SpanData, resource: sdk.Resource) void,
    forceFlushFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) otel_api.common.FlushResult,
    shutdownFn: *const fn (processor_ptr: *anyopaque, timeout_ms: ?u64) ProcessResult,
    deinitFn: *const fn (processor_ptr: *anyopaque) void,
    destroyFn: *const fn (processor_ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeSpanProcessor {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn spanLimits(pointer: *anyopaque) otel_api.trace.Span.Limits {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.spanLimits(self);
            }
            pub fn onEnd(pointer: *anyopaque, span: sdk.trace.SpanData, resource: sdk.Resource) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.onEnd(self, span, resource);
            }
            pub fn forceFlush(pointer: *anyopaque, timeout_ms: ?u64) otel_api.common.FlushResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.forceFlush(self, timeout_ms);
            }
            pub fn shutdown(pointer: *anyopaque, timeout_ms: ?u64) ProcessResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.shutdown(self, timeout_ms);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
            pub fn destroy(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.destroy(self);
            }
        };

        return .{
            .processor_ptr = ptr,
            .spanLimitsFn = VTable.spanLimits,
            .onEndFn = VTable.onEnd,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
        };
    }
};
