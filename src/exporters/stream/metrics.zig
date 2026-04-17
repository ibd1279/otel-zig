//! MetricDataSink that writes the log records to a configured *std.Io.Writer.

const std = @import("std");
const api = @import("otel-api");
const sdk = @import("otel-sdk");


const exporters = struct {
    const stream = struct {
        const SinkConfig = @import("config.zig");
    };
};

const MetricDataSink = @This();

pub const PipelineStep = sdk.common.PipelineStepInstructions(
    MetricDataSink,
    sdk.metrics.MetricExporter,
    exporters.stream.SinkConfig,
    metricsExporter,
    _init,
    sdk.common.PipelineDeinitConnection,
);
allocator: std.mem.Allocator,
config: exporters.stream.SinkConfig,
is_shutdown: std.atomic.Value(bool),
mutex: std.atomic.Mutex,

pub fn _init(self: *MetricDataSink, config: exporters.stream.SinkConfig, allocator: std.mem.Allocator) !void {
    self.* = init(allocator, config);
}

pub fn init(allocator: std.mem.Allocator, config: exporters.stream.SinkConfig) MetricDataSink {
    return .{
        .allocator = allocator,
        .config = config,
        .is_shutdown = .init(false),
        .mutex = .unlocked,
    };
}
pub fn deinit(_: *MetricDataSink) void {}
pub fn destroy(self: *MetricDataSink) void {
    self.allocator.destroy(self);
}

pub fn exportMetrics(self: *MetricDataSink, metrics: []const sdk.metrics.MetricData) api.common.ExportResult {
    if (self.is_shutdown.load(.monotonic)) return .success;

    while (!self.mutex.tryLock()) {}
    defer self.mutex.unlock();

    var result = api.common.ExportResult.success;
    for (metrics) |metric| {
        outputMetricData(metric.resource, self.config, metric) catch |err| {
            api.common.reportError(.{
                .component = .exporter,
                .operation = "MetricDataSink.exportRecords",
                .error_type = .serialization,
                .message = "Failed to write metric",
                .context = metric.name,
                .source_error = err,
            });

            result = .failure;
        };
    }

    return result;
}

pub fn forceFlush(self: *MetricDataSink, timeout_ms: ?u64) api.common.ExportResult {
    _ = timeout_ms;

    while (!self.mutex.tryLock()) {}
    defer self.mutex.unlock();

    self.config.writer.flush() catch return .failure;
    return .success;
}

pub fn shutdown(self: *MetricDataSink, timeout_ms: ?u64) api.common.ExportResult {
    if (self.is_shutdown.swap(true, .monotonic)) return .success;
    return self.forceFlush(timeout_ms);
}

pub fn metricsExporter(self: *MetricDataSink) sdk.metrics.MetricExporter {
    return .{ .bridge = sdk.metrics.BridgeMetricExporter.init(self) };
}

fn outputMetricData(resource: sdk.resource.Resource, cfg: exporters.stream.SinkConfig, metric: sdk.metrics.MetricData) !void {
    if (cfg.include_timestamp) {
        // Use the first data point's timestamp if available, else 0
        const ts_ns: i64 = @truncate(if (metric.data_points.len > 0) metric.data_points[0].timestamp.toNanoseconds() else 0);
        // Convert nanoseconds to seconds for display
        const timestamp_s = @divTrunc(ts_ns, 1_000_000_000);
        try cfg.writer.print("{d}|", .{timestamp_s});
    }
    const level = "METER";
    try cfg.writer.print("{s:<5} {s} ", .{ level, metric.name });

    // Datapoints
    for (metric.data_points) |point| {
        if (cfg.include_timestamp) {
            if (point.start_timestamp) |start_ts| {
                try cfg.writer.print("{f}@{d}-{d} ", .{ point.value, start_ts.toNanoseconds(), point.timestamp.toNanoseconds() });
            } else try cfg.writer.print("{f}@{d} ", .{ point.value, point.timestamp.toNanoseconds() });
        } else try cfg.writer.print("{f} ", .{point.value});
        if (cfg.include_attributes and point.attributes.len > 0) {
            try cfg.writer.print("| [", .{});
            for (point.attributes) |attr| {
                try cfg.writer.print("{f},", .{attr});
            }
            try cfg.writer.print("] ", .{});
        }
    }

    // Instrumentation Scope
    try cfg.writer.print("| name={s} ", .{metric.scope.name});
    if (metric.scope.version) |version| try cfg.writer.print("vers={s} ", .{version});
    if (metric.scope.schema_url) |url| try cfg.writer.print("schema={s} ", .{url});
    if (cfg.include_attributes and metric.scope.attributes.len > 0) {
        try cfg.writer.print("[", .{});
        for (metric.scope.attributes) |attr| {
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
