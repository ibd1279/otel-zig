//! OpenTelemetry Span Exporter Interface
//!
//! This module defines the SpanExporter interface for exporting spans
//! to various backends. Exporters are responsible for serializing and
//! transmitting span data to their destinations.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md#span-exporter

const std = @import("std");
const otel_api = @import("otel-api");

const ExportResult = otel_api.common.ExportResult;
const SpanData = @import("data.zig").SpanData;
const Resource = @import("../resource/resource.zig").Resource;

/// SpanExporter interface using tagged union for polymorphism
pub const SpanExporter = union(enum) {
    noop: void,
    bridge: BridgeSpanExporter,

    /// Export a batch of spans.
    ///
    /// The caller is required to manage `spans`. The exporter must be finished with
    /// the memory when this function returns. That includes making deep copies if
    /// necessary for buffering.
    pub fn exportSpans(self: *const SpanExporter, spans: []const SpanData, resource: Resource) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.exportFn(exporter, spans, resource),
        };
    }

    /// Force flush any buffered data
    pub fn forceFlush(self: *const SpanExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.forceFlushFn(exporter, timeout_ms),
        };
    }

    /// Shutdown the exporter
    pub fn shutdown(self: *const SpanExporter, timeout_ms: ?u64) ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.shutdownFn(exporter, timeout_ms),
        };
    }

    /// Clean up exporter resources
    pub fn deinit(self: *const SpanExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.deinitFn(exporter),
        }
    }

    /// Destroy exporter memory
    pub fn destroy(self: *const SpanExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.destroyFn(exporter.exporter_ptr),
        }
    }
};

/// Custom exporter with user-provided implementation
pub const BridgeSpanExporter = struct {
    exporter_ptr: *anyopaque,
    exportFn: *const fn (self: BridgeSpanExporter, spans: []const SpanData, resource: Resource) ExportResult,
    forceFlushFn: *const fn (self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult,
    shutdownFn: *const fn (self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult,
    deinitFn: *const fn (self: BridgeSpanExporter) void,
    destroyFn: *const fn (ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeSpanExporter {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn exportSpans(self: BridgeSpanExporter, spans: []const SpanData, resource: Resource) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.exportSpans(actual_self, spans, resource);
            }
            pub fn forceFlush(self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.forceFlush(actual_self, timeout_ms);
            }
            pub fn shutdown(self: BridgeSpanExporter, timeout_ms: ?u64) ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.shutdown(actual_self, timeout_ms);
            }
            pub fn deinit(self: BridgeSpanExporter) void {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.deinit(actual_self);
            }
            pub fn destroy(pointer: *anyopaque) void {
                const actual_self: T = @ptrCast(@alignCast(pointer));
                actual_self.destroy();
            }
        };

        return .{
            .exporter_ptr = ptr,
            .exportFn = VTable.exportSpans,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
        };
    }
};

/// Mock span exporter for testing purposes
/// Captures exported spans for verification without external dependencies.
pub const MockSpanExporter = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        Self,
        SpanExporter,
        void,
        spanExporter,
        _init,
        @import("../common/pipeline.zig").PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, _: void, allocator: std.mem.Allocator) !void {
        self.* = init(allocator);
    }

    allocator: std.mem.Allocator,
    exported_spans: std.ArrayList(SpanData),
    export_result: ExportResult,
    flush_result: ExportResult,
    shutdown_result: ExportResult,
    /// Optional pointer to a caller-owned bool. When set, deinit() writes true
    /// through it so callers can observe cleanup without touching freed memory.
    deinit_notify: ?*bool,

    pub fn init(allocator: std.mem.Allocator) MockSpanExporter {
        return .{
            .allocator = allocator,
            .exported_spans = .empty,
            .export_result = .success,
            .flush_result = .success,
            .shutdown_result = .success,
            .deinit_notify = null,
        };
    }

    pub fn deinit(self: *MockSpanExporter) void {
        if (self.deinit_notify) |ptr| ptr.* = true;
        for (self.exported_spans.items) |span| span.deinitOwned(self.allocator);
        self.exported_spans.deinit(self.allocator);
    }

    pub fn destroy(self: *MockSpanExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportSpans(self: *MockSpanExporter, spans: []const SpanData, resource: Resource) ExportResult {
        _ = resource;
        for (spans) |span| {
            // Deep-copy so attributes remain valid after the source RecordingSpan is freed.
            const owned = SpanData.initOwned(self.allocator, span) catch return .failure;
            self.exported_spans.append(self.allocator, owned) catch {
                owned.deinitOwned(self.allocator);
                return .failure;
            };
        }
        return self.export_result;
    }

    pub fn forceFlush(self: *MockSpanExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.flush_result;
    }

    pub fn shutdown(self: *MockSpanExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        return self.shutdown_result;
    }

    pub fn spanExporter(self: *MockSpanExporter) SpanExporter {
        return SpanExporter{ .bridge = BridgeSpanExporter.init(self) };
    }

    // Test helpers
    pub fn clearSpans(self: *MockSpanExporter) void {
        for (self.exported_spans.items) |span| span.deinitOwned(self.allocator);
        self.exported_spans.clearRetainingCapacity();
    }

    pub fn spanCount(self: *const MockSpanExporter) usize {
        return self.exported_spans.items.len;
    }

    pub fn getSpan(self: *const MockSpanExporter, index: usize) ?SpanData {
        if (index >= self.exported_spans.items.len) return null;
        return self.exported_spans.items[index];
    }
};
