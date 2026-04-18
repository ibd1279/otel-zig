const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const protobuf = @import("protobuf");

const ExportResult = otel_api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const MetricData = otel_sdk.metrics.MetricData;
const MetricDataPoint = otel_sdk.metrics.MetricDataPoint;
const MetricType = otel_sdk.metrics.MetricType;
const MetricExporter = otel_sdk.metrics.MetricExporter;
const convert = @import("convert.zig");

// Import error handler for structured error reporting
const error_handler = otel_api.common;

// Import protobuf definitions
const metrics_v1 = @import("proto/opentelemetry/proto/metrics/v1.pb.zig");
const common_v1 = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("proto/opentelemetry/proto/resource/v1.pb.zig");

pub const OtlpMetricExporter = struct {
    pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
        Self,
        otel_sdk.metrics.MetricExporter,
        OtlpExporterConfig,
        metricsExporter,
        _init,
        otel_sdk.common.PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, ctx: OtlpExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, ctx);
    }

    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool = false,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) OtlpMetricExporter {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OtlpMetricExporter) void {
        _ = self;
    }

    pub fn destroy(self: *OtlpMetricExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportMetrics(self: *OtlpMetricExporter, metrics: []const MetricData) ExportResult {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        if (self.is_shutdown) {
            return .failure;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const metrics_data = convertToOtlpFormat(arena.allocator(), metrics) catch |err| {
            const first_metric_name = if (metrics.len > 0) metrics[0].name else "(no metrics)";
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_serialization",
                .error_type = .serialization,
                .message = "OTLP metrics conversion failed",
                .context = first_metric_name,
                .source_error = err,
            });
            return .failure;
        };

        self.sendRequest(arena.allocator(), metrics_data) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_network",
                .error_type = .network,
                .message = "OTLP metrics network request failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return .failure;
        };

        return .success;
    }

    pub fn forceFlush(self: *OtlpMetricExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        // For HTTP-based exporters, force flush is typically a no-op
        // since each export call is synchronous
        return .success;
    }

    pub fn shutdown(self: *OtlpMetricExporter, timeout_ms: ?u64) ExportResult {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        _ = timeout_ms;
        self.is_shutdown = true;
        return .success;
    }

    pub fn metricsExporter(self: *OtlpMetricExporter) MetricExporter {
        return .{
            .bridge = otel_sdk.metrics.BridgeMetricExporter.init(self),
        };
    }

    fn sendRequest(self: *OtlpMetricExporter, allocator: std.mem.Allocator, metrics_data: metrics_v1.MetricsData) !void {
        var client = std.http.Client{ .allocator = allocator, .io = self.config.io };
        defer client.deinit();

        // Serialize to binary protobuf
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        try metrics_data.encode(&buffer.writer, allocator);
        const protobuf_bytes = try buffer.toOwnedSlice();
        defer allocator.free(protobuf_bytes);

        // Parse endpoint URL with detailed error context
        const base_uri = std.Uri.parse(self.config.endpoint) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_url_parsing",
                .error_type = .configuration,
                .message = "OTLP metrics URL parsing failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return err;
        };

        // Build full URL with metrics path
        const host_str = switch (base_uri.host.?) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        const scheme_str = if (base_uri.scheme.len > 0) base_uri.scheme else "http";
        const full_url = try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme_str, host_str, base_uri.port orelse 4318, self.config.protocol_config.metrics_path });
        defer allocator.free(full_url);

        // Add custom headers from config (simplified approach)
        var extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len);
        defer allocator.free(extra_headers);
        for (self.config.headers, 0..) |header, h| {
            extra_headers[h] = header;
        }

        // Create HTTP request
        const full_uri = try std.Uri.parse(full_url);
        var req = try client.request(.POST, full_uri, .{
            .headers = .{
                .content_type = .{ .override = "application/x-protobuf" },
                .user_agent = .{ .override = "otel-zig-otlp" },
            },
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        // Set request headers
        req.transfer_encoding = .{ .content_length = @intCast(protobuf_bytes.len) };

        // Send request
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(protobuf_bytes);
        try bw.end();
        try req.connection.?.flush();

        const res = try req.receiveHead(&.{});

        if (res.head.status != .ok) {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_metric_response",
                .error_type = .authentication,
                .message = "OTLP metrics export failed with HTTP error",
                .context = self.config.endpoint,
            });
            return error.ExportFailed;
        }
    }
};

/// Create a console metric exporter with custom configuration
pub fn createMetricExporterWithConfig(config: OtlpExporterConfig, allocator: std.mem.Allocator) !otel_sdk.metrics.MetricExporter {
    const exporter = try allocator.create(OtlpMetricExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = OtlpMetricExporter.init(allocator, config);
    return exporter.metricsExporter();
}

fn convertToOtlpFormat(allocator: std.mem.Allocator, metrics: []const MetricData) !metrics_v1.MetricsData {
    var resource_metrics_map = std.StringHashMap(std.ArrayList(MetricData)).init(allocator);
    defer {
        var it = resource_metrics_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        resource_metrics_map.deinit();
    }

    // Group metrics by resource
    for (metrics) |metric| {
        // Group by service name if available, otherwise use empty string
        const resource_key = if (otel_api.AttributeKeyValue.scanSlice(metric.resource.attributes, "service.name")) |attr|
            attr.value.string
        else
            "";
        const result = try resource_metrics_map.getOrPut(resource_key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(MetricData).empty;
        }
        try result.value_ptr.append(allocator, metric);
    }

    var metrics_data = metrics_v1.MetricsData{};

    var resource_it = resource_metrics_map.iterator();
    while (resource_it.next()) |entry| {
        const resource_metrics = entry.value_ptr.*;
        if (resource_metrics.items.len == 0) continue;

        // Convert resource
        var rm = metrics_v1.ResourceMetrics{
            .resource = try convert.resourceToProto(allocator, resource_metrics.items[0].resource),
        };

        // Group by instrumentation scope
        var scope_map = std.StringHashMap(std.ArrayList(MetricData)).init(allocator);
        defer {
            var it = scope_map.iterator();
            while (it.next()) |scope_entry| {
                scope_entry.value_ptr.deinit(allocator);
            }
            scope_map.deinit();
        }

        for (resource_metrics.items) |metric| {
            const scope_name = metric.scope.name;
            const result = try scope_map.getOrPut(scope_name);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(MetricData).empty;
            }
            try result.value_ptr.append(allocator, metric);
        }

        var scope_it = scope_map.iterator();
        while (scope_it.next()) |scope_entry| {
            const scope_metrics = scope_entry.value_ptr.*;
            if (scope_metrics.items.len == 0) continue;

            // Convert instrumentation scope
            var sm = metrics_v1.ScopeMetrics{
                .scope = try convert.instrumentationScopeToProto(allocator, scope_metrics.items[0].scope),
            };

            // Convert metrics
            for (scope_metrics.items) |metric_data| {
                var metric = metrics_v1.Metric{
                    .name = try allocator.dupe(u8, metric_data.name),
                    .description = try allocator.dupe(u8, metric_data.description orelse ""),
                    .unit = try allocator.dupe(u8, metric_data.unit orelse ""),
                };

                // Convert metric data based on type
                switch (metric_data.type) {
                    .sum => {
                        metric.data = .{ .sum = .{
                            .aggregation_temporality = .AGGREGATION_TEMPORALITY_DELTA,
                            .data_points = try convertNumberDataPoints(allocator, metric_data.data_points),
                        } };
                    },
                    .gauge => {
                        metric.data = .{ .gauge = .{
                            .data_points = try convertNumberDataPoints(allocator, metric_data.data_points),
                        } };
                    },
                    .histogram => {
                        metric.data = .{ .histogram = .{
                            .aggregation_temporality = .AGGREGATION_TEMPORALITY_DELTA,
                            .data_points = try convertHistogramDataPoints(allocator, metric_data.data_points),
                        } };
                    },
                }

                try sm.metrics.append(allocator, metric);
            }

            try rm.scope_metrics.append(allocator, sm);
        }

        try metrics_data.resource_metrics.append(allocator, rm);
    }

    return metrics_data;
}

fn convertNumberDataPoints(allocator: std.mem.Allocator, data_points: []const MetricDataPoint) !std.ArrayList(metrics_v1.NumberDataPoint) {
    var result = std.ArrayList(metrics_v1.NumberDataPoint).empty;

    for (data_points) |dp| {
        var ndp = metrics_v1.NumberDataPoint{
            .time_unix_nano = @intCast(dp.timestamp.toNanoseconds()),
            .start_time_unix_nano = if (dp.start_timestamp) |ts| @intCast(ts.toNanoseconds()) else 0,
        };

        // Convert attributes
        for (dp.attributes) |attr| {
            try ndp.attributes.append(allocator, try convert.attributeKeyValueToProto(allocator, attr));
        }

        // Set value based on type
        switch (dp.value) {
            .i64_gauge => |i| ndp.value = .{ .as_int = i },
            .f64_gauge => |d| ndp.value = .{ .as_double = d },
            .i64_sum => |i| ndp.value = .{ .as_int = i },
            .f64_sum => |d| ndp.value = .{ .as_double = d },
            .i64_histogram, .f64_histogram => unreachable, // Histogram data points are handled separately
        }

        try result.append(allocator, ndp);
    }

    return result;
}

fn convertHistogramDataPoints(allocator: std.mem.Allocator, data_points: []const MetricDataPoint) !std.ArrayList(metrics_v1.HistogramDataPoint) {
    var result = std.ArrayList(metrics_v1.HistogramDataPoint).empty;

    for (data_points) |dp| {
        var hdp = metrics_v1.HistogramDataPoint{
            .time_unix_nano = @intCast(dp.timestamp.toNanoseconds()),
            .start_time_unix_nano = if (dp.start_timestamp) |ts| @intCast(ts.toNanoseconds()) else 0,
        };

        // Convert attributes
        for (dp.attributes) |attr| {
            try hdp.attributes.append(allocator, try convert.attributeKeyValueToProto(allocator, attr));
        }

        switch (dp.value) {
            .i64_histogram => |h| {
                hdp.count = h.count;
                hdp.sum = @floatFromInt(h.sum);

                for (h.bucket_counts) |count| {
                    try hdp.bucket_counts.append(allocator, count);
                }

                for (h.boundaries) |bound| {
                    try hdp.explicit_bounds.append(allocator, bound);
                }

                hdp.min = if (h.min) |min| @floatFromInt(min) else null;
                hdp.max = if (h.max) |max| @floatFromInt(max) else null;
            },
            .f64_histogram => |h| {
                hdp.count = h.count;
                hdp.sum = h.sum;

                for (h.bucket_counts) |count| {
                    try hdp.bucket_counts.append(allocator, count);
                }

                for (h.boundaries) |bound| {
                    try hdp.explicit_bounds.append(allocator, bound);
                }

                hdp.min = h.min;
                hdp.max = h.max;
            },
            else => unreachable, // Only histogram data points should be passed here
        }

        try result.append(allocator, hdp);
    }

    return result;
}

test "convertToOtlpFormat with histogram" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test resource
    const resource_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "test-service" } },
    };
    const resource = otel_sdk.resource.Resource{ .attributes = &resource_attrs };

    // Create test instrumentation scope
    const scope = otel_api.InstrumentationScope{
        .name = "test-scope",
        .version = "1.0.0",
    };

    // Create test histogram data
    const boundaries = [_]f64{ 1.0, 5.0, 10.0 };
    const bucket_counts = [_]u64{ 2, 3, 1, 0 };
    const histogram = otel_sdk.metrics.F64HistogramData{
        .count = 6,
        .sum = 25.5,
        .min = 0.5,
        .max = 9.2,
        .boundaries = &boundaries,
        .bucket_counts = &bucket_counts,
    };

    const data_point = otel_sdk.metrics.MetricDataPoint{
        .attributes = &[_]otel_api.common.AttributeKeyValue{},
        .timestamp = std.Io.Timestamp.fromNanoseconds(1234567890),
        .start_timestamp = std.Io.Timestamp.fromNanoseconds(1234567000),
        .value = .{ .f64_histogram = histogram },
    };

    const metric_data = otel_sdk.metrics.MetricData{
        .resource = resource,
        .scope = scope,
        .name = "test_histogram",
        .description = "A test histogram",
        .unit = "ms",
        .type = .histogram,
        .data_points = &[_]otel_sdk.metrics.MetricDataPoint{data_point},
    };

    const metrics = [_]otel_sdk.metrics.MetricData{metric_data};
    var result = try convertToOtlpFormat(allocator, &metrics);
    defer result.deinit(allocator);

    try testing.expect(result.resource_metrics.items.len == 1);
    const rm = result.resource_metrics.items[0];
    try testing.expect(rm.scope_metrics.items.len == 1);

    const sm = rm.scope_metrics.items[0];
    try testing.expect(sm.metrics.items.len == 1);

    const metric = sm.metrics.items[0];
    try testing.expect(std.mem.eql(u8, metric.name, "test_histogram"));

    if (metric.data) |data| {
        switch (data) {
            .histogram => |hist| {
                try testing.expect(hist.data_points.items.len == 1);
                const hdp = hist.data_points.items[0];
                try testing.expectEqual(@as(u64, 6), hdp.count);
                if (hdp.sum) |sum| {
                    try testing.expectApproxEqAbs(@as(f64, 25.5), sum, 0.001);
                } else {
                    try testing.expect(false); // sum should be present
                }
            },
            else => try testing.expect(false),
        }
    } else {
        try testing.expect(false);
    }
}
