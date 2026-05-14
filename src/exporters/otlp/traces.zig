//! OpenTelemetry Protocol (OTLP) Trace Exporter
//!
//! This module provides an OTLP exporter for trace spans that sends
//! data to OTLP-compatible backends using HTTP/JSON transport.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const protobuf = @import("protobuf");

const ExportResult = otel_api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const RecordingSpan = otel_sdk.trace.RecordingSpan;
const Resource = otel_sdk.resource.Resource;
const SpanContext = otel_api.trace.SpanContext;

// Import error handler for structured error reporting
const error_handler = otel_api.common;
const SpanExporter = otel_sdk.trace.SpanExporter;
const convert = @import("convert.zig");

const common_v1 = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("proto/opentelemetry/proto/resource/v1.pb.zig");
const trace_v1 = @import("proto/opentelemetry/proto/trace/v1.pb.zig");

/// OTLP trace exporter implementation
pub const OtlpTraceExporter = struct {
    pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
        OtlpTraceExporter,
        SpanExporter,
        OtlpExporterConfig,
        spanExporter,
        _init,
        otel_sdk.common.PipelineDeinitConnection,
    );

    pub fn _init(self: *OtlpTraceExporter, config: OtlpExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, config);
    }

    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool,
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) OtlpTraceExporter {
        return .{
            .config = config,
            .allocator = allocator,
            .is_shutdown = false,
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *OtlpTraceExporter) void {
        _ = self;
    }

    pub fn destroy(self: *OtlpTraceExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportSpans(self: *OtlpTraceExporter, spans: []const otel_sdk.trace.SpanData, resource: Resource) ExportResult {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        if (self.is_shutdown) {
            return .failure;
        }

        if (spans.len == 0) {
            return .success;
        }

        // Local arena for the OTLP transform and network send
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var span_data = convertToOtlpFormat(arena.allocator(), spans, resource) catch |err| {
            const first_span_name = if (spans.len > 0) spans[0].name else "(no spans)";
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_trace_serialization",
                .error_type = .serialization,
                .message = "OTLP trace JSON conversion failed",
                .context = first_span_name,
                .source_error = err,
            });
            return .failure;
        };
        defer span_data.deinit(arena.allocator());

        const result = self.sendRequest(arena.allocator(), span_data) catch |err| {
            // Canceled means the caller's io was canceled (e.g. user pressed
            // Ctrl-C). Telemetry is best-effort; drop silently rather than
            // printing a confusing network error for a deliberate interruption.
            if (err == error.Canceled) return .dropped;
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_trace_network",
                .error_type = .network,
                .message = "OTLP trace network request failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return .failure;
        };

        return result;
    }

    pub fn forceFlush(self: *OtlpTraceExporter, timeout_ms: ?u64) ExportResult {
        _ = self;
        _ = timeout_ms;
        // For HTTP transport, no persistent connection to flush
        return .success;
    }

    pub fn shutdown(self: *OtlpTraceExporter, timeout_ms: ?u64) ExportResult {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        if (self.is_shutdown) {
            return .success;
        }

        self.is_shutdown = true;
        _ = timeout_ms;

        return .success;
    }

    pub fn spanExporter(self: *OtlpTraceExporter) SpanExporter {
        return SpanExporter{ .bridge = otel_sdk.trace.BridgeSpanExporter.init(self) };
    }

    fn sendRequest(self: *OtlpTraceExporter, allocator: std.mem.Allocator, traces_data: trace_v1.TracesData) !ExportResult {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.config.io };
        defer client.deinit();

        // Serialize to binary protobuf
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        try traces_data.encode(&buffer.writer, allocator); // protobuf encoding.
        // _ = try buffer.writer.write(try traces_data.jsonEncode(.{}, allocator)); // Json encoding.
        const protobuf_bytes = try buffer.toOwnedSlice();
        defer allocator.free(protobuf_bytes);

        // Parse endpoint URL with detailed error context
        const uri = std.Uri.parse(self.config.endpoint) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_url_parsing",
                .error_type = .configuration,
                .message = "OTLP URL parsing failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return err;
        };

        // Build full URL with traces path
        const host_str = switch (uri.host.?) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        const scheme_str = if (uri.scheme.len > 0) uri.scheme else "http";
        const full_url = try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme_str, host_str, uri.port orelse 4318, self.config.protocol_config.traces_path });
        defer allocator.free(full_url);

        // Add custom headers from config (simplified approach)
        var extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len);
        defer allocator.free(extra_headers);
        for (self.config.headers, 0..) |header, h| {
            extra_headers[h] = header;
        }

        // Create HTTP request
        var resp_writer = std.Io.Writer.Allocating.init(allocator);
        defer resp_writer.deinit();

        const full_uri = try std.Uri.parse(full_url);

        const req = try client.fetch(std.http.Client.FetchOptions{
            .location = .{ .uri = full_uri },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/x-protobuf" },
                .user_agent = .{ .override = "otel-zig-otlp" },
            },
            .extra_headers = extra_headers,
            .response_writer = &resp_writer.writer,
            .payload = protobuf_bytes,
        });

        const result_status_code = req.status;
        const result_body = try resp_writer.toOwnedSlice();
        defer allocator.free(result_body);

        switch (result_status_code) {
            .ok => return .success,
            .bad_request => {
                // const error_context = try std.fmt.allocPrint(allocator, "{s}\ncurl -X POST -H 'Content-Type: application/json' -d '{s}' http://localhost:4318/v1/traces", .{ result_body, protobuf_bytes });
                // defer allocator.free(error_context);
                const error_context = try std.fmt.allocPrint(allocator, "{t}-{s}", .{ result_status_code, result_body });
                defer allocator.free(error_context);
                error_handler.reportError(.{
                    .component = .exporter,
                    .operation = "otlp_trace_response",
                    .error_type = .unknown,
                    .message = "OTLP trace export failed with HTTP error",
                    .context = error_context,
                });
                return .failure;
            },
            .unauthorized, .forbidden, .not_found => {
                error_handler.reportError(.{
                    .component = .exporter,
                    .operation = "otlp_trace_response",
                    .error_type = .authentication,
                    .message = "OTLP trace export failed with HTTP error",
                    .context = self.config.endpoint,
                });
                return .failure;
            },
            else => {
                const error_context = try std.fmt.allocPrint(allocator, "{t}-{s}", .{ result_status_code, result_body });
                defer allocator.free(error_context);

                error_handler.reportError(.{
                    .component = .exporter,
                    .operation = "otlp_trace_response",
                    .error_type = .authentication,
                    .message = "OTLP trace export failed with HTTP error",
                    .context = error_context,
                });
                return .failure;
            },
        }
    }
};

fn convertToOtlpFormat(allocator: std.mem.Allocator, spans: []const otel_sdk.trace.SpanData, resource: Resource) !trace_v1.TracesData {
    var traces_data = trace_v1.TracesData{};

    var rs = trace_v1.ResourceSpans{
        .resource = try convert.resourceToProto(allocator, resource),
    };

    // Group by instrumentation scope
    var scope_map = std.StringHashMap(std.ArrayList(otel_sdk.trace.SpanData)).init(allocator);
    defer {
        var it = scope_map.iterator();
        while (it.next()) |scope_entry| {
            scope_entry.value_ptr.deinit(allocator);
        }
        scope_map.deinit();
    }

    for (spans) |span| {
        const scope_name = span.scope.name;
        const result = try scope_map.getOrPut(scope_name);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(otel_sdk.trace.SpanData).empty;
        }
        try result.value_ptr.append(allocator, span);
    }

    var scope_it = scope_map.iterator();
    while (scope_it.next()) |scope_entry| {
        const scope_spans = scope_entry.value_ptr.*;
        if (scope_spans.items.len == 0) continue;

        // Convert instrumentation scope
        var ss = trace_v1.ScopeSpans{
            .scope = try convert.instrumentationScopeToProto(allocator, scope_spans.items[0].scope),
        };

        // Convert Span
        for (scope_spans.items) |span_data| {
            // var tid_buf = [_]u8{0} ** (otel_api.common.TraceId.length * 2);
            // var sid_buf = [_]u8{0} ** (otel_api.common.SpanId.length * 2);
            // var psid_buf = [_]u8{0} ** (otel_api.common.SpanId.length * 2);
            var span = trace_v1.Span{
                .trace_id = try allocator.dupe(u8, span_data.ctx.trace_id.bytes[0..]),
                .span_id = try allocator.dupe(u8, span_data.ctx.span_id.bytes[0..]),
                .parent_span_id = if (span_data.parent_ctx) |pctx| try allocator.dupe(u8, pctx.span_id.bytes[0..]) else &.{},
                .name = try allocator.dupe(u8, span_data.name),
                .start_time_unix_nano = @intCast(span_data.start_time.toNanoseconds()),
                .end_time_unix_nano = @intCast(span_data.end_time.toNanoseconds()),
                .flags = @intCast(span_data.ctx.trace_flags),
                .kind = @enumFromInt(@intFromEnum(span_data.kind)),
                .trace_state = if (span_data.ctx.trace_state) |ts| try allocator.dupe(u8, ts) else &.{},
                .dropped_attributes_count = 0,
                .dropped_events_count = 0,
                .dropped_links_count = 0,
            };

            // sub objects
            if (span_data.status.code != .unset) {
                span.status = trace_v1.Status{
                    .code = @enumFromInt(@intFromEnum(span_data.status.code)),
                    .message = if (span_data.status.description) |desc| try allocator.dupe(u8, desc) else &.{},
                };
            }

            if (span_data.attributes.len > 0) {
                for (span_data.attributes) |attr| {
                    try span.attributes.append(allocator, try convert.attributeKeyValueToProto(allocator, attr));
                }
            }

            if (span_data.events.len > 0) {
                for (span_data.events) |span_event| {
                    var event = trace_v1.Span.Event{
                        .name = try allocator.dupe(u8, span_event.name),
                        .time_unix_nano = @intCast((span_event.timestamp orelse std.Io.Timestamp.zero).toNanoseconds()),
                        .dropped_attributes_count = 0,
                    };
                    for (span_event.attributes) |attr| {
                        try event.attributes.append(allocator, try convert.attributeKeyValueToProto(allocator, attr));
                    }
                    try span.events.append(allocator, event);
                }
            }

            if (span_data.links.len > 0) {
                for (span_data.links) |span_link| {
                    var link = trace_v1.Span.Link{
                        .dropped_attributes_count = 0,
                        .flags = @intCast(span_link.span_context.trace_flags),
                        .span_id = try allocator.dupe(u8, span_link.span_context.span_id.bytes[0..]),
                        .trace_id = try allocator.dupe(u8, span_link.span_context.trace_id.bytes[0..]),
                        .trace_state = if (span_link.span_context.trace_state) |ts| try allocator.dupe(u8, ts) else &.{},
                    };
                    for (span_link.attributes) |attr| {
                        try link.attributes.append(allocator, try convert.attributeKeyValueToProto(allocator, attr));
                    }
                    try span.links.append(allocator, link);
                }
            }

            try ss.spans.append(allocator, span);
        }

        try rs.scope_spans.append(allocator, ss);
    }

    try traces_data.resource_spans.append(allocator, rs);

    return traces_data;
}

/// Create an OTLP trace exporter with default configuration
pub fn createTraceExporter(allocator: std.mem.Allocator, io: std.Io) !SpanExporter {
    const exporter = try allocator.create(OtlpTraceExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = OtlpTraceExporter.init(allocator, .{ .io = io });
    return exporter.spanExporter();
}

/// Create an OTLP trace exporter with custom configuration
pub fn createTraceExporterWithConfig(config: OtlpExporterConfig, allocator: std.mem.Allocator) !SpanExporter {
    const exporter = try allocator.create(OtlpTraceExporter);
    errdefer allocator.destroy(exporter);
    exporter.* = OtlpTraceExporter.init(allocator, config);
    return exporter.spanExporter();
}

test "OtlpTraceExporter basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = OtlpTraceExporter.init(allocator, .{ .io = std.testing.io });
    defer exporter.deinit();

    const result = exporter.forceFlush(5000);
    try testing.expectEqual(ExportResult.success, result);

    const shutdown_result = exporter.shutdown(5000);
    try testing.expectEqual(ExportResult.success, shutdown_result);
}
