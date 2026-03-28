const std = @import("std");
const api = @import("otel-api");
const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
};

/// Metric data point representing a single measurement
pub const MetricDataPoint = struct {
    /// Timestamp when the measurement was recorded
    timestamp: std.Io.Timestamp,
    /// Start timestamp for monotonic counters (null for gauges)
    start_timestamp: ?std.Io.Timestamp,
    /// Attributes associated with this data point
    attributes: []const api.AttributeKeyValue,
    /// The actual value
    value: MetricValue,
};

/// Histogram data for i64 values
pub const I64HistogramData = struct {
    count: u64,
    sum: i64,
    min: ?i64,
    max: ?i64,
    boundaries: []const f64,
    bucket_counts: []const u64,

    /// Formats the histogram data into a human-readable string
    pub fn format(
        self: I64HistogramData,
        writer: anytype,
    ) !void {
        try writer.print("Histogram{{ count = {d}, sum = {d}, boundaries = {any}, bucket_counts = {any}", .{
            self.count,
            self.sum,
            self.boundaries,
            self.bucket_counts,
        });
        if (self.min) |min| try writer.print(" min={d}", .{min});
        if (self.max) |max| try writer.print(" max={d}", .{max});
        try writer.print(" }}", .{});
    }
};

/// Histogram data for f64 values
pub const F64HistogramData = struct {
    count: u64,
    sum: f64,
    min: ?f64,
    max: ?f64,
    boundaries: []const f64,
    bucket_counts: []const u64,

    /// Formats the histogram data into a human-readable string
    pub fn format(
        self: F64HistogramData,
        writer: anytype,
    ) !void {
        try writer.print("Histogram{{ count = {d}, sum = {d}, boundaries = {any}, bucket_counts = {any}", .{
            self.count,
            self.sum,
            self.boundaries,
            self.bucket_counts,
        });
        if (self.min) |min| try writer.print(" min={d}", .{min});
        if (self.max) |max| try writer.print(" max={d}", .{max});
        try writer.print(" }}", .{});
    }
};

/// Possible metric values
pub const MetricValue = union(enum) {
    i64_sum: i64,
    f64_sum: f64,
    i64_gauge: i64,
    f64_gauge: f64,
    i64_histogram: I64HistogramData,
    f64_histogram: F64HistogramData,

    pub fn format(
        self: MetricValue,
        writer: anytype,
    ) !void {
        switch (self) {
            .i64_sum => |v| try writer.print("{d}", .{v}),
            .f64_sum => |v| try writer.print("{d}", .{v}),
            .i64_gauge => |v| try writer.print("{d}", .{v}),
            .f64_gauge => |v| try writer.print("{d}", .{v}),
            .i64_histogram => |v| try v.format(writer),
            .f64_histogram => |v| try v.format(writer),
        }
    }
};

/// Aggregated metric data
pub const MetricData = struct {
    /// Instrument name
    name: []const u8,
    /// Instrument description
    description: ?[]const u8,
    /// Unit of measurement
    unit: ?[]const u8,
    /// Type of metric
    type: MetricType,
    /// Aggregated data points
    data_points: []const MetricDataPoint,
    /// Instrumentation scope that created this metric
    scope: api.InstrumentationScope,
    /// Resource associated with this metric
    resource: sdk.Resource,

    /// Formats the metric data into a human-readable string
    pub fn format(
        self: MetricData,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}({s})/points={}", .{
            self.name,
            @tagName(self.type),
            self.data_points.len,
        });
        if (self.data_points.len > 0) {
            try writer.print("{{", .{});
            for (self.data_points) |point| {
                try writer.print("{any}", .{point});
            }
            try writer.print("}}", .{});
        }
        try writer.print(" {}/{}", .{
            self.scope,
            self.resource,
        });
    }
};

pub const MetricType = enum {
    sum,
    gauge,
    histogram,
};
