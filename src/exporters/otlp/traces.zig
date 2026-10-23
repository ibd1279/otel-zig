//! OpenTelemetry Protocol (OTLP) Trace Exporter
//!
//! This module provides an OTLP exporter for trace spans that sends
//! data to OTLP-compatible backends using OTLP/HTTP protobuf or JSON.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const ExportResult = otel_api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const RecordingSpan = otel_sdk.trace.RecordingSpan;
const Resource = otel_sdk.resource.Resource;
const SpanContext = otel_api.trace.SpanContext;

// Import error handler for structured error reporting
const error_handler = otel_api.common;
const SpanExporter = otel_sdk.trace.SpanExporter;
const convert = @import("convert.zig");
const otlp_transport = @import("transport_backend.zig").transport;

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
        // Runtime protocol selection (REQ-1): exporter stays backend-unaware;
        // the transport backend chosen by build flag + config.protocol carries
        // the batch. gRPC always carries protobuf in the unary frame.
        const is_grpc = self.config.protocol == .grpc;
        if (is_grpc and self.config.compression != .none) {
            // gRPC client-side compression is out of scope; fail loud instead
            // of silently sending a mismatched content-encoding.
            return error.GrpcCompressionUnsupported;
        }
        const content_type: []const u8 = if (is_grpc)
            "application/grpc"
        else switch (self.config.transport) {
            .http_protobuf => "application/x-protobuf",
            .http_json => "application/json",
            .grpc => return error.UnsupportedTransport,
        };
        const encoded: []const u8 = if (is_grpc or self.config.transport == .http_protobuf) encoded: {
            var buffer = std.Io.Writer.Allocating.init(allocator);
            defer buffer.deinit();
            try traces_data.encode(&buffer.writer, allocator);
            break :encoded try buffer.toOwnedSlice();
        } else try traces_data.jsonEncode(.{}, .{}, allocator);
        defer allocator.free(encoded);

        var compressed = std.Io.Writer.Allocating.init(allocator);
        defer compressed.deinit();
        const payload = switch (self.config.compression) {
            .none => encoded,
            .gzip => payload: {
                try compressed.ensureUnusedCapacity(1024);
                var history: [std.compress.flate.max_window_len]u8 = undefined;
                var compressor = try std.compress.flate.Compress.init(
                    &compressed.writer,
                    &history,
                    .gzip,
                    .default,
                );
                try compressor.writer.writeAll(encoded);
                try compressor.finish();
                break :payload compressed.written();
            },
        };

        const full_url = try otlp_transport.signalUrl(allocator, self.config, self.config.protocol_config.traces_path);
        defer allocator.free(full_url);

        // Add custom headers from config.
        const compression_headers: usize = if (self.config.compression == .gzip) 1 else 0;
        var extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len + compression_headers);
        defer allocator.free(extra_headers);
        for (self.config.headers, 0..) |header, h| {
            extra_headers[h] = header;
        }
        if (self.config.compression == .gzip) {
            extra_headers[self.config.headers.len] = .{ .name = "content-encoding", .value = "gzip" };
        }

        return otlp_transport.post(self.allocator, allocator, self.config, full_url, content_type, extra_headers, payload, "trace");
    }
};

const joinSignalPath = otlp_transport.joinSignalPath;

test "trace endpoint preserves configured paths" {
    const testing = std.testing;
    const generic = try joinSignalPath(testing.allocator, "https://collector.example/base/", "/v1/traces");
    defer testing.allocator.free(generic);
    try testing.expectEqualStrings("https://collector.example/base/v1/traces", generic);
    const specific = try joinSignalPath(testing.allocator, "https://collector.example/custom", "");
    defer testing.allocator.free(specific);
    try testing.expectEqualStrings("https://collector.example/custom", specific);
}

const TestRequestCapture = struct {
    target: [256]u8 = undefined,
    target_len: usize = 0,
    body: [64 * 1024]u8 = undefined,
    body_len: usize = 0,
    content_type: [64]u8 = undefined,
    content_type_len: usize = 0,
    content_encoding: [32]u8 = undefined,
    content_encoding_len: usize = 0,
    api_key: [64]u8 = undefined,
    api_key_len: usize = 0,

    fn targetSlice(self: *const TestRequestCapture) []const u8 {
        return self.target[0..self.target_len];
    }

    fn bodySlice(self: *const TestRequestCapture) []const u8 {
        return self.body[0..self.body_len];
    }

    fn contentType(self: *const TestRequestCapture) []const u8 {
        return self.content_type[0..self.content_type_len];
    }

    fn contentEncoding(self: *const TestRequestCapture) []const u8 {
        return self.content_encoding[0..self.content_encoding_len];
    }

    fn apiKey(self: *const TestRequestCapture) []const u8 {
        return self.api_key[0..self.api_key_len];
    }
};

const TestCollector = struct {
    fn copyHeader(destination: []u8, length: *usize, value: []const u8) !void {
        if (value.len > destination.len) return error.HeaderTooLong;
        @memcpy(destination[0..value.len], value);
        length.* = value.len;
    }

    fn receive(listener: *std.Io.net.Server, io: std.Io, capture: *TestRequestCapture) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();

        if (request.head.target.len > capture.target.len) return error.TargetTooLong;
        @memcpy(capture.target[0..request.head.target.len], request.head.target);
        capture.target_len = request.head.target.len;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                try copyHeader(&capture.content_type, &capture.content_type_len, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "content-encoding")) {
                try copyHeader(&capture.content_encoding, &capture.content_encoding_len, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                try copyHeader(&capture.api_key, &capture.api_key_len, header.value);
            }
        }

        var body_buffer: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        var body_writer = std.Io.Writer.fixed(&capture.body);
        _ = try body_reader.streamRemaining(&body_writer);
        capture.body_len = body_writer.buffered().len;
        try request.respond("", .{ .status = .ok, .keep_alive = false });
    }

    fn receiveAndStall(listener: *std.Io.net.Server, io: std.Io, delay_ms: u64) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        var body_buffer: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        var discard_buffer: [64 * 1024]u8 = undefined;
        var discard = std.Io.Writer.fixed(&discard_buffer);
        _ = try body_reader.streamRemaining(&discard);
        try io.sleep(.{ .nanoseconds = @intCast(delay_ms * std.time.ns_per_ms) }, .awake);
    }

    fn receiveRetrySequence(listener: *std.Io.net.Server, io: std.Io) !void {
        const statuses = [_]std.http.Status{ .service_unavailable, .too_many_requests, .accepted };
        for (statuses, 0..) |status, index| {
            var stream = try listener.accept(io);
            defer stream.close(io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            const retry_after: []const std.http.Header = if (index == 1)
                &.{.{ .name = "retry-after", .value = "0" }}
            else
                &.{};
            try request.respond("", .{ .status = status, .keep_alive = false, .extra_headers = retry_after });
        }
    }

    fn receiveRetryAfterOneSecond(listener: *std.Io.net.Server, io: std.Io) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        try request.respond("", .{
            .status = .too_many_requests,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "retry-after", .value = "1" }},
        });
    }
};

fn testSpan(name: []const u8) otel_sdk.trace.SpanData {
    return .{
        .scope = .{ .name = "offline-test" },
        .ctx = .{
            .trace_id = .{ .bytes = @splat(1) },
            .span_id = .{ .bytes = @splat(2) },
            .trace_flags = 1,
            .trace_state = null,
            .is_remote = false,
        },
        .parent_ctx = null,
        .name = name,
        .kind = .internal,
        .status = .{ .code = .ok },
        .start_time = std.Io.Timestamp.zero,
        .end_time = .{ .nanoseconds = 2 },
        .attributes = &.{},
        .events = &.{},
        .links = &.{},
    };
}

test "OTLP JSON export uses the generic endpoint path and configured headers" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var capture: TestRequestCapture = .{};
    var collector = try io.concurrent(TestCollector.receive, .{ &listener, io, &capture });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/collector", .{listener.socket.address.getPort()});
    const headers = [_]std.http.Header{.{ .name = "x-api-key", .value = "offline-secret" }};
    var exporter = OtlpTraceExporter.init(testing.allocator, .{
        .endpoint = endpoint,
        .io = io,
        .transport = .http_json,
        .headers = &headers,
        .timeout_millis = 1_000,
    });
    const spans = [_]otel_sdk.trace.SpanData{testSpan("offline-json-span")};
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, .{
        .attributes = &.{.{ .key = "service.name", .value = .{ .string = "stream-test" } }},
    }));
    try collector.await(io);

    try testing.expectEqualStrings("/collector/v1/traces", capture.targetSlice());
    try testing.expectEqualStrings("application/json", capture.contentType());
    try testing.expectEqualStrings("offline-secret", capture.apiKey());
    try testing.expect(std.mem.indexOf(u8, capture.bodySlice(), "offline-json-span") != null);
    try testing.expect(std.mem.indexOf(u8, capture.bodySlice(), "stream-test") != null);
}

test "OTLP protobuf export sends a real gzip body to a traces-specific endpoint" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var capture: TestRequestCapture = .{};
    var collector = try io.concurrent(TestCollector.receive, .{ &listener, io, &capture });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/custom/traces", .{listener.socket.address.getPort()});
    var exporter = OtlpTraceExporter.init(testing.allocator, .{
        .endpoint = endpoint,
        .io = io,
        .transport = .http_protobuf,
        .compression = .gzip,
        .append_signal_path = false,
        .timeout_millis = 1_000,
    });
    const spans = [_]otel_sdk.trace.SpanData{testSpan("offline-protobuf-span")};
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, .empty));
    try collector.await(io);

    try testing.expectEqualStrings("/custom/traces", capture.targetSlice());
    try testing.expectEqualStrings("application/x-protobuf", capture.contentType());
    try testing.expectEqualStrings("gzip", capture.contentEncoding());
    try testing.expect(capture.body_len > 2);
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, capture.bodySlice()[0..2]);
    var compressed_reader: std.Io.Reader = .fixed(capture.bodySlice());
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&compressed_reader, .gzip, &history);
    var protobuf_buffer: [64 * 1024]u8 = undefined;
    var protobuf_writer = std.Io.Writer.fixed(&protobuf_buffer);
    _ = try decompressor.reader.streamRemaining(&protobuf_writer);
    try testing.expect(std.mem.indexOf(u8, protobuf_writer.buffered(), "offline-protobuf-span") != null);
}

test "OTLP HTTP export cancels a stalled collector at the configured timeout" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var collector = try io.concurrent(TestCollector.receiveAndStall, .{ &listener, io, 250 });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    var exporter = OtlpTraceExporter.init(testing.allocator, .{
        .endpoint = endpoint,
        .io = io,
        .transport = .http_json,
        .timeout_millis = 30,
        .retry_config = .{ .enabled = false },
    });
    const spans = [_]otel_sdk.trace.SpanData{testSpan("timeout-span")};
    const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    try testing.expectEqual(ExportResult.failure, exporter.exportSpans(&spans, .empty));
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - started;
    try testing.expect(elapsed < 200 * std.time.ns_per_ms);
}

test "OTLP HTTP export retries upstream statuses and honors Retry-After" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var collector = try io.concurrent(TestCollector.receiveRetrySequence, .{ &listener, io });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    var exporter = OtlpTraceExporter.init(testing.allocator, .{
        .endpoint = endpoint,
        .io = io,
        .transport = .http_json,
        .timeout_millis = 1_000,
        .export_timeout_millis = 500,
        .retry_config = .{
            .initial_interval_millis = 5,
            .max_interval_millis = 5,
            .max_elapsed_time_millis = 500,
            .jitter = false,
        },
    });
    const spans = [_]otel_sdk.trace.SpanData{testSpan("retry-span")};
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, .empty));
    try collector.await(io);
}

test "OTLP BSP export timeout caps Retry-After and the complete retry lifecycle" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var collector = try io.concurrent(TestCollector.receiveRetryAfterOneSecond, .{ &listener, io });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    var exporter = OtlpTraceExporter.init(testing.allocator, .{
        .endpoint = endpoint,
        .io = io,
        .transport = .http_json,
        .timeout_millis = 1_000,
        .export_timeout_millis = 40,
        .retry_config = .{ .max_elapsed_time_millis = 1_000, .jitter = false },
    });
    const spans = [_]otel_sdk.trace.SpanData{testSpan("export-timeout-span")};
    const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    try testing.expectEqual(ExportResult.failure, exporter.exportSpans(&spans, .empty));
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - started;
    try testing.expect(elapsed < 200 * std.time.ns_per_ms);
    try collector.await(io);
}

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
                .kind = @fromBackingInt(@intCast(@backingInt(span_data.kind))),
                .trace_state = if (span_data.ctx.trace_state) |ts| try allocator.dupe(u8, ts) else &.{},
                .dropped_attributes_count = 0,
                .dropped_events_count = 0,
                .dropped_links_count = 0,
            };

            // sub objects
            if (span_data.status.code != .unset) {
                span.status = trace_v1.Status{
                    .code = @fromBackingInt(@intCast(@backingInt(span_data.status.code))),
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

test "OTLP trace protobuf bytes are stable" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var span_attributes = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "http.method", .value = .{ .string = "GET" } },
        .{ .key = "http.status_code", .value = .{ .int = 503 } },
        .{ .key = "retry", .value = .{ .bool = true } },
        .{ .key = "ratio", .value = .{ .float = 0.25 } },
    };
    var span = testSpan("golden-span");
    span.parent_ctx = .{
        .trace_id = span.ctx.trace_id,
        .span_id = .{ .bytes = @as([8]u8, @splat(3)) },
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = true,
    };
    span.kind = .server;
    span.status = .{ .code = .@"error", .description = "upstream unavailable" };
    span.start_time = std.Io.Timestamp.fromNanoseconds(1_700_000_000_000_000_000);
    span.end_time = std.Io.Timestamp.fromNanoseconds(1_700_000_000_250_000_000);
    span.attributes = &span_attributes;
    const resource_attributes = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "golden" } },
    };
    const spans = [_]otel_sdk.trace.SpanData{span};
    var traces_data = try convertToOtlpFormat(allocator, &spans, .{ .attributes = &resource_attributes });
    var buffer = std.Io.Writer.Allocating.init(allocator);
    try traces_data.encode(&buffer.writer, allocator);

    const hex = try std.fmt.allocPrint(allocator, "{x}", .{buffer.written()});
    try testing.expectEqualStrings(golden_trace_hex, hex);
}

// Recorded from zig 0.16 with zig-protobuf 4.0.0; pins the OTLP wire bytes
// across compiler and protobuf upgrades.
const golden_trace_hex =
    "0ae9010a1a0a180a0c736572766963652e6e616d6512080a06676f6c64656e12ca010a0e0a0c6f66666c696e652d7465" ++
    "737412b7010a100101010101010101010101010101010112080202020202020202220803030303030303038501010000" ++
    "002a0b676f6c64656e2d7370616e30023900002a36fe9c97174180b21045fe9c97174a140a0b687474702e6d6574686f" ++
    "6412050a034745544a170a10687474702e7374617475735f636f6465120318f7034a0b0a057265747279120210014a12" ++
    "0a05726174696f120921000000000000d03f7a181214757073747265616d20756e617661696c61626c651802";
