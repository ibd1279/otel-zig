//! LogRecordDataSink that writes the log records to a configured *std.Io.Writer.

const std = @import("std");
const api = @import("otel-api");
const sdk = @import("otel-sdk");


const exporters = struct {
    const stream = struct {
        const SinkConfig = @import("config.zig");
    };
};

const LogRecordSink = @This();

pub const PipelineStep = sdk.common.PipelineStepInstructions(
    LogRecordSink,
    sdk.logs.LogRecordExporter,
    exporters.stream.SinkConfig,
    logRecordExporter,
    _init,
    sdk.common.PipelineDeinitConnection,
);
allocator: std.mem.Allocator,
config: exporters.stream.SinkConfig,
is_shutdown: std.atomic.Value(bool),
mutex: std.atomic.Mutex,

pub fn _init(self: *LogRecordSink, config: exporters.stream.SinkConfig, allocator: std.mem.Allocator) !void {
    self.* = init(allocator, config);
}

pub fn init(allocator: std.mem.Allocator, config: exporters.stream.SinkConfig) LogRecordSink {
    return .{
        .allocator = allocator,
        .config = config,
        .is_shutdown = .init(false),
        .mutex = .unlocked,
    };
}
pub fn deinit(_: *LogRecordSink) void {}
pub fn destroy(self: *LogRecordSink) void {
    self.allocator.destroy(self);
}

pub fn exportRecords(self: *LogRecordSink, records: []const sdk.logs.LogRecord, resource: sdk.resource.Resource) api.common.ExportResult {
    if (self.is_shutdown.load(.monotonic)) return .success;

    while (!self.mutex.tryLock()) {}
    defer self.mutex.unlock();

    var result = api.common.ExportResult.success;
    for (records) |rec| {
        outputLogRecord(resource, self.config, rec) catch |err| {
            const message_body = if (rec.body) |body| switch (body) {
                .string => |str| str,
                else => "(non-string message)",
            } else "(no message)";

            api.common.reportError(.{
                .component = .exporter,
                .operation = "LogRecordSink.exportRecords",
                .error_type = .serialization,
                .message = "Failed to write log record",
                .context = message_body,
                .source_error = err,
            });

            result = .failure;
        };
    }

    return result;
}

pub fn forceFlush(self: *LogRecordSink, timeout_ms: ?u64) api.common.ExportResult {
    _ = timeout_ms;

    while (!self.mutex.tryLock()) {}
    defer self.mutex.unlock();

    self.config.writer.flush() catch return .failure;
    return .success;
}

pub fn shutdown(self: *LogRecordSink, timeout_ms: ?u64) api.common.ExportResult {
    if (self.is_shutdown.swap(true, .monotonic)) return .success;
    return self.forceFlush(timeout_ms);
}

pub fn logRecordExporter(self: *LogRecordSink) sdk.logs.LogRecordExporter {
    return .{ .bridge = sdk.logs.BridgeLogRecordExporter.init(self) };
}

fn outputLogRecord(resource: sdk.resource.Resource, cfg: exporters.stream.SinkConfig, record: sdk.logs.LogRecord) !void {
    if (cfg.include_timestamp) {
        const ts_ns = if (record.timestamp) |ts| ts.toNanoseconds() else if (record.observed_timestamp) |ts| ts.toNanoseconds() else 0;
        // Convert nanoseconds to seconds for display
        const timestamp_s = @divTrunc(ts_ns, 1_000_000_000);
        try cfg.writer.print("{d}|", .{timestamp_s});
    }
    const level = record.severity_number.toShortText();
    const body = record.body orelse api.common.AttributeValue{ .string = "(no message)" };
    try cfg.writer.print("{s:<5} {f} ", .{ level, body });
    if (record.instrumentation_scope) |scope| {
        try cfg.writer.print("| name={s} ", .{scope.name});
        if (scope.version) |version| try cfg.writer.print("vers={s} ", .{version});
        if (scope.schema_url) |url| try cfg.writer.print("schema={s} ", .{url});
        if (cfg.include_attributes and scope.attributes.len > 0) {
            try cfg.writer.print("[", .{});
            for (scope.attributes) |attr| {
                try cfg.writer.print("{f},", .{attr});
            }
            try cfg.writer.print("] ", .{});
        }
    }
    if (cfg.include_resource and resource.attributes.len > 0) {
        try cfg.writer.print("| [", .{});
        for (resource.attributes) |attr| {
            try cfg.writer.print("{f},", .{attr});
        }
        try cfg.writer.print("] ", .{});
    }
    if (cfg.include_attributes) {
        try cfg.writer.print("| [", .{});
        for (record.attributes) |attr| {
            try cfg.writer.print("{f},", .{attr});
        }
        try cfg.writer.print("] ", .{});
    }
    try cfg.writer.print("\n", .{});
    if (cfg.flush_after_each) try cfg.writer.flush();
}
