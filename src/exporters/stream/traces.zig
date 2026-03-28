//! SpanDataSink that writes the log records to a configured *std.Io.Writer.
const std = @import("std");
const api = @import("otel-api");
const sdk = @import("otel-sdk");


const exporters = struct {
    const stream = struct {
        const SinkConfig = @import("config.zig");
    };
};

const SpanDataSink = @This();

pub const PipelineStep = sdk.common.PipelineStepInstructions(
    SpanDataSink,
    sdk.trace.SpanExporter,
    exporters.stream.SinkConfig,
    spanExporter,
    _init,
    sdk.common.PipelineDeinitConnection,
);
allocator: std.mem.Allocator,
config: exporters.stream.SinkConfig,
is_shutdown: std.atomic.Value(bool),
mutex: std.Thread.Mutex,

pub fn _init(self: *SpanDataSink, config: exporters.stream.SinkConfig, allocator: std.mem.Allocator) !void {
    self.* = init(allocator, config);
}

pub fn init(allocator: std.mem.Allocator, config: exporters.stream.SinkConfig) SpanDataSink {
    return .{
        .allocator = allocator,
        .config = config,
        .is_shutdown = .init(false),
        .mutex = .{},
    };
}
pub fn deinit(_: *SpanDataSink) void {}
pub fn destroy(self: *SpanDataSink) void {
    self.allocator.destroy(self);
}

pub fn exportSpans(
    self: *SpanDataSink,
    spans: []const sdk.trace.SpanData,
    resource: sdk.resource.Resource,
) api.common.ExportResult {
    if (self.is_shutdown.load(.monotonic)) return .success;

    self.mutex.lock();
    defer self.mutex.unlock();

    var result = api.common.ExportResult.success;
    for (spans) |span| {
        outputSpanData(resource, self.config, span) catch |err| {
            api.common.reportError(.{
                .component = .exporter,
                .operation = "SpanDataSink.exportSpans",
                .error_type = .serialization,
                .message = "Failed to write span",
                .context = span.name,
                .source_error = err,
            });

            result = .failure;
        };
    }

    return result;
}

pub fn forceFlush(self: *SpanDataSink, timeout_ms: ?u64) api.common.ExportResult {
    _ = timeout_ms;

    self.mutex.lock();
    defer self.mutex.unlock();

    self.config.writer.flush() catch return .failure;
    return .success;
}

pub fn shutdown(self: *SpanDataSink, timeout_ms: ?u64) api.common.ExportResult {
    if (self.is_shutdown.swap(true, .monotonic)) return .success;
    return self.forceFlush(timeout_ms);
}

pub fn spanExporter(self: *SpanDataSink) sdk.trace.SpanExporter {
    return .{ .bridge = sdk.trace.BridgeSpanExporter.init(self) };
}

fn outputSpanData(resource: sdk.resource.Resource, cfg: exporters.stream.SinkConfig, span: sdk.trace.SpanData) !void {
    if (cfg.include_timestamp) {
        // Convert nanoseconds to seconds for display
        const timestamp_s = @divTrunc(span.start_time.toNanoseconds(), 1_000_000_000);
        try cfg.writer.print("{d}|", .{timestamp_s});
    }
    const level = "SPAN ";
    try cfg.writer.print("{s:<5} {s} {t} {t} ", .{ level, span.name, span.kind, span.status.code });
    if (span.status.description) |desc| try cfg.writer.print("{s} ", .{desc});
    try cfg.writer.print("| {d}-{d} ", .{ span.start_time.toNanoseconds(), span.end_time.toNanoseconds() });
    if (span.parent_ctx) |parent| {
        var trace_id_buff: [api.common.TraceId.length * 2]u8 = undefined;
        span.ctx.trace_id.toHexString(&trace_id_buff);
        var span_id_buff: [api.common.SpanId.length * 2]u8 = undefined;
        span.ctx.span_id.toHexString(&span_id_buff);
        var parent_span_id_buff: [api.common.SpanId.length * 2]u8 = undefined;
        parent.span_id.toHexString(&parent_span_id_buff);

        try cfg.writer.print("| {s} {s} {s} ", .{ trace_id_buff[0..], span_id_buff[0..], parent_span_id_buff[0..] });
    } else {
        var trace_id_buff: [api.common.TraceId.length * 2]u8 = undefined;
        span.ctx.trace_id.toHexString(&trace_id_buff);
        var span_id_buff: [api.common.SpanId.length * 2]u8 = undefined;
        span.ctx.span_id.toHexString(&span_id_buff);
        try cfg.writer.print("| {s} {s} ", .{ trace_id_buff[0..], span_id_buff[0..] });
    }
    for (span.events) |event| {
        try cfg.writer.print("| event {d} {s} ", .{ (event.timestamp orelse std.Io.Timestamp.zero).toNanoseconds(), event.name });
        if (cfg.include_resource) {
            if (event.attributes.len > 0) {
                try cfg.writer.print("[", .{});
                for (event.attributes) |attr| {
                    try cfg.writer.print("{f},", .{attr});
                }
                try cfg.writer.print("] ", .{});
            }
        }
    }
    for (span.links) |link| {
        try cfg.writer.print("| link {x} {x} ", .{ link.span_context.span_id.bytes, link.span_context.trace_id.bytes });
        if (cfg.include_resource) {
            if (link.attributes.len > 0) {
                try cfg.writer.print("[", .{});
                for (link.attributes) |attr| {
                    try cfg.writer.print("{f},", .{attr});
                }
                try cfg.writer.print("] ", .{});
            }
        }
    }

    // Instrumentation Scope
    try cfg.writer.print("| name={s} ", .{span.scope.name});
    if (span.scope.version) |version| try cfg.writer.print("vers={s} ", .{version});
    if (span.scope.schema_url) |url| try cfg.writer.print("schema={s} ", .{url});
    if (cfg.include_attributes and span.scope.attributes.len > 0) {
        try cfg.writer.print("[", .{});
        for (span.scope.attributes) |attr| {
            try cfg.writer.print("{f},", .{attr});
        }
        try cfg.writer.print("] ", .{});
    }

    // Resource
    if (cfg.include_resource and resource.attributes.len > 0) {
        try cfg.writer.print("| [", .{});
        for (resource.attributes) |attr| {
            try cfg.writer.print("{f},", .{attr});
        }
        try cfg.writer.print("] ", .{});
    }

    try cfg.writer.print("\n", .{});
    if (cfg.flush_after_each) try cfg.writer.flush();
}
