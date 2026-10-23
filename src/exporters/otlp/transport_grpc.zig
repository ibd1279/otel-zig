//! httpx.zig-backed OTLP/gRPC transport variant (opt-in via `-Dotlp-httpx`).
//!
//! Compiled in TOGETHER with `transport_httpx.zig` behind the single
//! `-Dotlp-httpx` flag (decision D3 — no second build flag); the exporter
//! selects it at runtime via `OtlpExporterConfig.protocol = .grpc`. The
//! dispatcher lives in `transport_httpx.post`; this module is only imported
//! from httpx-family code, so a default build fetches zero httpx and never
//! references any of this.
//!
//! Wire shape (REQ-7): a gRPC unary request over HTTP/2 — 1-byte compression
//! flag (zero) + 4-byte big-endian payload length + protobuf payload, with
//! `content-type: application/grpc` and `te: trailers`, targeting the
//! per-signal OTLP gRPC method path on port 4317 by default (URL/method
//! construction is protocol-aware in `transport.signalUrl`).
//!
//! Response handling (decisions D1/D2): `grpc-status` is read from the
//! response headers — httpx's h2 client transport merges initial and trailer
//! HEADERS into one flat list, so trailers-only responses are covered — and
//! mapped to a synthetic `std.http.Status` that feeds the SHARED retry layer
//! (`postWithPerform`) unchanged. Unmapped codes map to a synthetic 500
//! (non-retryable, `.unknown`). On success `Response.body` carries the
//! de-framed payload; a missing body frame (trailers-only response or empty
//! DATA) leaves it empty with frame parsing skipped. On failure the backend
//! substitutes `grpc-message` as the body text.
//!
//! Retry ownership stays solely in `transport.postWithPerform` — this file
//! contains zero retry logic. httpx upstream retry/pooling/interceptors are
//! structurally absent here: the h2 `http2.transport.Client` has no retry
//! machinery, and each attempt dials a fresh connection (fail-fast, one
//! request per attempt). The mTLS guard is NOT duplicated — it lives in the
//! shared `postWithPerform` loop.
//!
//! TLS (REQ-8) reuses the httpx backend's `LoadedTls` ownership pattern: the
//! CA bundle PEM is loaded for the lifetime of the export and freed only in
//! `deinit`, preventing the use-after-free class fixed in 98eea4d. Over TLS
//! the h2 connection is negotiated via ALPN (`h2` only).

const std = @import("std");
const httpx = @import("httpx");
const otel_api = @import("otel-api");
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const ExportResult = otel_api.common.ExportResult;

const base = @import("transport.zig");
const httpx_backend = @import("transport_httpx.zig");

// Shared hardening: panics-free raw HTTP status conversion (finding 3 of the
// PR #5 review) lives in the httpx backend and is reused here.
const safeHttpStatus = httpx_backend.safeHttpStatus;
const otel_sdk = @import("otel-sdk");
const otlp_traces = @import("traces.zig");

fn testSpan(name: []const u8) otel_sdk.trace.SpanData {
    return .{
        .scope = .{ .name = "grpc-scenario-test" },
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

const error_handler = otel_api.common;

pub const Response = base.Response;
pub const signalUrl = base.signalUrl;
pub const joinSignalPath = base.joinSignalPath;
pub const isRetryableStatus = base.isRetryableStatus;
pub const retryDelay = base.retryDelay;
pub const nextInterval = base.nextInterval;
pub const grpcMethodPath = base.grpcMethodPath;

const GrpcStatus = struct {
    /// "grpc-status" (a decimal u32), when present.
    status: ?u32,
    /// "grpc-message" (percent-encoded per the gRPC HTTP/2 spec).
    message: ?[]const u8,
    /// "grpc-retry-after" (decimal seconds), when present.
    retry_after_seconds: ?u64,
};

/// Maps a gRPC status code to a synthetic `std.http.Status` so the shared
/// `isRetryableStatus`/`retryDelay` path is reused unchanged (REQ-7):
///   0 → 200, 8 ResourceExhausted → 429, 14 Unavailable → 503,
///   4 DeadlineExceeded → 504, 16 Unauthenticated → 401,
///   1 Canceled → 499-equivalent (existing non-retryable set).
/// ANY code not in this table maps to a synthetic 500 — non-retryable,
/// reported with the `.unknown` error class by the shared layer (D1).
pub fn mapGrpcStatus(code: u32) std.http.Status {
    return switch (code) {
        0 => .ok,
        8 => .too_many_requests,
        14 => .service_unavailable,
        4 => .gateway_timeout,
        16 => .unauthorized,
        1 => @fromBackingInt(@intCast(499)), // Canceled: non-retryable client-error class
        else => .internal_server_error,
    };
}

/// Frames a request payload as a gRPC unary message: 1-byte compression flag
/// (zero — client-side compression is out of scope) + 4-byte big-endian
/// payload length + payload (SC-13).
pub fn framePayload(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const framed = try allocator.alloc(u8, 5 + payload.len);
    errdefer allocator.free(framed);
    framed[0] = 0; // compression flag: none
    std.mem.writeInt(u32, framed[1..5], @intCast(payload.len), .big);
    @memcpy(framed[5..], payload);
    return framed;
}

/// De-frames a response DATA payload. Per decision D2: no frame (empty DATA
/// or a trailers-only response, where the body is empty) yields an empty
/// payload and frame parsing is skipped. A nonzero compression flag or a
/// truncated length prefix is a protocol error, not a silent guess.
pub fn unframePayload(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return allocator.alloc(u8, 0);
    if (data.len < 5) return error.GrpcFrameInvalid;
    if (data[0] != 0) return error.GrpcCompressionUnsupported;
    const length = std.mem.readInt(u32, data[1..5], .big);
    if (data.len < 5 + length) return error.GrpcFrameInvalid;
    return allocator.dupe(u8, data[5 .. 5 + length]);
}

/// Percent-decodes a `grpc-message` value so the surfaced error context is
/// human-readable (the gRPC HTTP/2 spec percent-encodes per RFC 3986).
fn decodeGrpcMessage(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var decoded = try std.Io.Writer.Allocating.initCapacity(allocator, encoded.len);
    errdefer decoded.deinit();
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hex = encoded[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                try decoded.writer.writeByte(encoded[i]);
                i += 1;
                continue;
            };
            try decoded.writer.writeByte(byte);
            i += 3;
        } else {
            try decoded.writer.writeByte(encoded[i]);
            i += 1;
        }
    }
    return decoded.toOwnedSlice();
}

/// POST `payload` to `url` as an OTLP/gRPC unary request, retrying through
/// the shared otel-zig retry layer only. Signature and return contract match
/// the default std.http transport exactly (PostFn).
pub fn post(
    client_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    config: OtlpExporterConfig,
    url: []const u8,
    content_type: []const u8,
    extra_headers: []const std.http.Header,
    payload: []const u8,
    signal: []const u8,
) !ExportResult {
    return base.postWithPerform(performGrpc, client_allocator, allocator, config, url, content_type, extra_headers, payload, signal);
}

/// One gRPC attempt. Issues exactly one HTTP/2 request on a fresh h2c or
/// h2-over-TLS connection. The per-attempt deadline is enforced by the
/// shared `attemptWithTimeout` wrapper on `config.io`.
fn performGrpc(
    client_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    config: OtlpExporterConfig,
    url: []const u8,
    uri: std.Uri,
    content_type: []const u8,
    extra_headers: []const std.http.Header,
    payload: []const u8,
    timeout_ms: u64,
) anyerror!Response {
    // The URL was already parsed (and the parse error surfaced through the
    // error handler) by the shared retry loop; `uri` carries the pieces the
    // h2 client needs as pseudo-header values.
    _ = url;
    return base.attemptWithTimeout(config, timeout_ms, grpcAttempt, .{
        client_allocator, allocator, config, uri, content_type, extra_headers, payload,
    });
}

fn uriComponent(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
}

fn grpcAttempt(
    client_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    config: OtlpExporterConfig,
    uri: std.Uri,
    content_type: []const u8,
    extra_headers: []const std.http.Header,
    payload: []const u8,
) anyerror!Response {
    const httpx_io = std.Io.Threaded.global_single_threaded.io();
    const host = uriComponent(uri.host orelse return error.InvalidUrl);
    const https = std.mem.eql(u8, uri.scheme, "https");
    const port: u16 = uri.port orelse @import("root.zig").grpc_default_port;
    const path = uriComponent(uri.path);
    const authority = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
    defer allocator.free(authority);

    // gRPC needs lowercase h2 header names (RFC 9113 Section 8.1), plus the
    // gRPC content-type, `te: trailers`, and the same otel-zig-otlp
    // User-Agent as every other backend (REQ-8/SC-17).
    var grpc_headers = try allocator.alloc(std.http.Header, extra_headers.len + 3);
    defer allocator.free(grpc_headers);
    grpc_headers[0] = .{ .name = "content-type", .value = content_type };
    grpc_headers[1] = .{ .name = "te", .value = "trailers" };
    grpc_headers[2] = .{ .name = "user-agent", .value = "otel-zig-otlp" };
    // Caller-supplied header names may be mixed-case; HPACK requires
    // lowercase field names on the wire (RFC 7541 Section 4.2) and httpx
    // encodes names verbatim, so normalize into scratch memory owned for
    // this attempt without mutating the caller's config.
    var scratch_len: usize = 0;
    for (extra_headers) |header| scratch_len += header.name.len;
    const lower_scratch = try allocator.alloc(u8, scratch_len);
    defer allocator.free(lower_scratch);
    var lower_off: usize = 0;
    for (extra_headers, 0..) |header, h| {
        const name = lower_scratch[lower_off..][0..header.name.len];
        lower_off += header.name.len;
        for (header.name, 0..) |c, i| name[i] = std.ascii.toLower(c);
        grpc_headers[3 + h] = .{ .name = name, .value = header.value };
    }
    comptime {
        std.debug.assert(@sizeOf(std.http.Header) == @sizeOf(httpx.http2.transport.Header));
        std.debug.assert(@offsetOf(std.http.Header, "name") == @offsetOf(httpx.http2.transport.Header, "name"));
        std.debug.assert(@offsetOf(std.http.Header, "value") == @offsetOf(httpx.http2.transport.Header, "value"));
    }
    const h2_headers: []const httpx.http2.transport.Header = @ptrCast(grpc_headers);

    const framed = try framePayload(allocator, payload);
    defer allocator.free(framed);

    const is_tls = https;
    var loaded_tls = if (is_tls) try httpx_backend.loadTlsOptions(allocator, config.io, config.tls_config) else httpx_backend.LoadedTls{};
    defer loaded_tls.deinit(allocator);

    // Fresh connection per attempt (fail-fast, single request per attempt —
    // the accepted per-request-handshake tradeoff of the httpx backend).
    // Dial: an IP literal connects directly; a hostname resolves through
    // httpx's resolver — the same path its own h2 client uses (tcp.connect
    // is literal-only and rejects names like "localhost").
    var sock = httpx.tcp.connect(httpx_io, host, port) catch |literal_err| blk: {
        if (literal_err != error.HostUnreachable) return literal_err;
        var resolver = httpx.resolve.Resolver.init(client_allocator, httpx_io);
        const addrs = resolver.lookup(host, .{ .port = port }) catch return error.ConnectFailed;
        defer client_allocator.free(addrs);
        var last_err: anyerror = error.ConnectFailed;
        for (addrs) |addr| {
            if (httpx.tcp.connectAddress(httpx_io, &addr)) |dial| {
                break :blk dial;
            } else |err| {
                last_err = err;
            }
        }
        return last_err;
    };
    var h2_client: *httpx.http2.transport.Client = undefined;
    // httpx's h2 client stores the TLS session as a POINTER
    // (`Stream.tls: *tlsClientMod.Client.Connection`), so the connection
    // must outlive `h2_client.request(...)` — declared at function scope,
    // not inside the `if (is_tls)` block, whose lifetime ends before the
    // request runs.
    var tls_conn: httpx.tls.Client.Connection = undefined;
    if (is_tls) {
        var tls_owner = httpx.tls.Client.init(client_allocator, httpx_io, .{}) catch |err| {
            sock.close();
            return mapTlsError(err);
        };
        defer tls_owner.deinit();
        const tls_options = loaded_tls.options orelse httpx.TlsOptions{};
        // httpx's native TLS client takes socket ownership on success.
        tls_conn = tls_owner.connect(&sock, host, .{
            .verify = tls_options.verify,
            .caPem = tls_options.caPem,
            .alpn = &.{.h2},
            .transport = .native,
        }) catch |err| {
            sock.close();
            return mapTlsError(err);
        };
        if (tls_conn.alpn() != .h2) {
            tls_conn.deinit();
            return error.AlpnNegotiationFailed;
        }
        h2_client = httpx.http2.transport.Client.connectTls(client_allocator, &tls_conn) catch |err| {
            tls_conn.deinit();
            return err;
        };
        // h2_client now owns the request path over `tls_conn`; its deinit
        // (below) closes the stream and the TLS session with it.
    } else {
        h2_client = httpx.http2.transport.Client.connect(client_allocator, sock) catch |err| {
            sock.close();
            return err;
        };
    }
    defer h2_client.deinit();

    var h2_response = try h2_client.request(
        "POST",
        path,
        h2_headers,
        if (https) "https" else "http",
        authority,
        framed,
    );
    defer h2_response.deinit();

    return grpcResponseFromH2(allocator, &h2_response);
}

/// Converts an httpx h2 exchange into the shared `Response`: grpc-status
/// mapped, grpc-message substituted on failure, grpc-retry-after carried as
/// `retry_after_millis` (REQ-7, SC-14/SC-15/SC-19/SC-20).
fn grpcResponseFromH2(allocator: std.mem.Allocator, h2_response: *httpx.http2.transport.Response) !Response {
    var wire_status = GrpcStatus{ .status = null, .message = null, .retry_after_seconds = null };
    for (h2_response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "grpc-status")) {
            // Duplicated grpc-status headers: last parseable value wins.
            wire_status.status = std.fmt.parseInt(u32, std.mem.trim(u8, header.value, " \t"), 10) catch wire_status.status;
        } else if (std.ascii.eqlIgnoreCase(header.name, "grpc-message")) {
            wire_status.message = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "grpc-retry-after")) {
            wire_status.retry_after_seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch wire_status.retry_after_seconds;
        }
    }

    var retry_after_millis: ?u64 = null;
    if (wire_status.retry_after_seconds) |seconds| retry_after_millis = seconds *| 1000;

    if (wire_status.status) |code| {
        const mapped = mapGrpcStatus(code);
        if (mapped == .ok) {
            // Success: body carries the de-framed payload; a trailers-only
            // response or empty DATA yields an empty body with frame parsing
            // skipped (D2/SC-20).
            const body = try unframePayload(allocator, h2_response.body);
            errdefer allocator.free(body);
            return .{ .status = mapped, .body = body, .retry_after_millis = null };
        }
        // Failure: substitute grpc-message as the body text so the shared
        // error context stays human-readable (D2).
        var body: []u8 = undefined;
        if (wire_status.message) |encoded| {
            body = try decodeGrpcMessage(allocator, encoded);
        } else {
            body = try allocator.alloc(u8, 0);
        }
        errdefer allocator.free(body);
        return .{ .status = mapped, .body = body, .retry_after_millis = retry_after_millis };
    }

    // No grpc-status header, or one that failed to parse: per the gRPC
    // HTTP/2 spec a response without a valid grpc-status is a FAILURE, not
    // success — reporting it as `.ok` would silently swallow gRPC errors.
    // An HTTP 2xx in this state maps to the synthetic non-retryable 500;
    // a non-2xx raw HTTP status (from whatever non-gRPC responder answered)
    // passes through unchanged, clamped to the valid 100–599 range.
    const body = try allocator.dupe(u8, blk: {
        if (h2_response.status >= 200 and h2_response.status < 300) break :blk @as([]const u8, "missing or unparseable grpc-status");
        break :blk h2_response.body;
    });
    errdefer allocator.free(body);
    const raw = h2_response.status;
    const status: std.http.Status = if (raw >= 200 and raw < 300)
        .internal_server_error
    else
        safeHttpStatus(raw);
    return .{
        .status = status,
        .body = body,
        .retry_after_millis = retry_after_millis,
    };
}

fn mapTlsError(err: anyerror) anyerror {
    // httpx's native TLS stack surfaces its own error names; map the
    // handshake/verification failures onto the same transport-level errors
    // the std.http backend produces for the same misconfigurations.
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CertificateVerifyFailed, error.HandshakeFailed => error.TlsInitializationFailed,
        else => err,
    };
}

// ---------------------------------------------------------------------------
// Golden-bytes framing tests (offline, deterministic — SC-13).
// ---------------------------------------------------------------------------

test "grpc framing produces the exact wire prefix bytes" {
    const testing = std.testing;
    const framed = try framePayload(testing.allocator, "hello");
    defer testing.allocator.free(framed);
    const expected = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try testing.expectEqualSlices(u8, &expected, framed);

    const empty = try framePayload(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00 }, empty);

    // Length is 4-byte big-endian: 256 crosses a byte boundary.
    const payload_256: [256]u8 = @splat(0xAB);
    const big = try framePayload(testing.allocator, &payload_256);
    defer testing.allocator.free(big);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01, 0x00 }, big[0..5]);
}

test "grpc unframing: full frame, empty body, nonzero flag, truncated length" {
    const testing = std.testing;
    const framed = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const payload = try unframePayload(testing.allocator, &framed);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("hello", payload);

    // No body frame at all: empty payload, parsing skipped (D2/SC-20).
    const none = try unframePayload(testing.allocator, "");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    try testing.expectError(error.GrpcCompressionUnsupported, unframePayload(testing.allocator, &[_]u8{ 0x01, 0, 0, 0, 0 }));
    try testing.expectError(error.GrpcFrameInvalid, unframePayload(testing.allocator, &[_]u8{ 0x00, 0x00, 0x00 }));
    try testing.expectError(error.GrpcFrameInvalid, unframePayload(testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x09, 'x' }));
}

// ---------------------------------------------------------------------------
// grpc-status mapping table tests, including the unmapped synthetic-500 case
// (D1/SC-19).
// ---------------------------------------------------------------------------

test "grpc status mapping table, including unmapped codes" {
    const testing = std.testing;
    const cases = [_]struct { code: u32, expected: std.http.Status }{
        .{ .code = 0, .expected = .ok },
        .{ .code = 8, .expected = .too_many_requests }, // ResourceExhausted
        .{ .code = 14, .expected = .service_unavailable }, // Unavailable
        .{ .code = 4, .expected = .gateway_timeout }, // DeadlineExceeded
        .{ .code = 16, .expected = .unauthorized }, // Unauthenticated
        .{ .code = 1, .expected = @fromBackingInt(@intCast(499)) }, // Canceled
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, mapGrpcStatus(case.code));
    }
    // Unmapped codes (3 InvalidArgument, 2 Unknown, 13 Internal, 255, ...):
    // synthetic 500.
    for ([_]u32{ 2, 3, 5, 9, 13, 255 }) |code| {
        try testing.expectEqual(std.http.Status.internal_server_error, mapGrpcStatus(code));
    }
    // The synthetic 500 must be non-retryable through the SHARED classifier,
    // and the mapped retryable statuses must be retryable — no gRPC-specific
    // retry code anywhere.
    try testing.expect(!isRetryableStatus(.internal_server_error));
    try testing.expect(isRetryableStatus(.too_many_requests));
    try testing.expect(isRetryableStatus(.service_unavailable));
    try testing.expect(isRetryableStatus(.gateway_timeout));
}

test "grpc-message percent-decoding" {
    const testing = std.testing;
    const decoded = try decodeGrpcMessage(testing.allocator, "invalid argument: 50%25 off");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("invalid argument: 50% off", decoded);

    const raw = try decodeGrpcMessage(testing.allocator, "no escapes");
    defer testing.allocator.free(raw);
    try testing.expectEqualStrings("no escapes", raw);

    // A dangling percent is surfaced verbatim, never truncated silently.
    const dangling = try decodeGrpcMessage(testing.allocator, "bad %2");
    defer testing.allocator.free(dangling);
    try testing.expectEqualStrings("bad %2", dangling);
}

// ---------------------------------------------------------------------------
// Protocol-aware port defaulting and method-path mapping (SC-2, REQ-7).
// ---------------------------------------------------------------------------

test "grpc signalUrl: port-less endpoint defaults to 4317 with the method path" {
    const testing = std.testing;
    const url = try signalUrl(testing.allocator, .{
        .io = std.testing.io,
        .endpoint = "http://collector.example",
        .protocol = .grpc,
    }, "/v1/traces");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("http://collector.example:4317/opentelemetry.proto.collector.trace.v1.TraceService/Export", url);

    const metrics = try signalUrl(testing.allocator, .{
        .io = std.testing.io,
        .endpoint = "http://collector.example",
        .protocol = .grpc,
    }, "/v1/metrics");
    defer testing.allocator.free(metrics);
    try testing.expectEqualStrings("http://collector.example:4317/opentelemetry.proto.collector.metrics.v1.MetricsService/Export", metrics);

    const logs = try signalUrl(testing.allocator, .{
        .io = std.testing.io,
        .endpoint = "http://collector.example",
        .protocol = .grpc,
    }, "/v1/logs");
    defer testing.allocator.free(logs);
    try testing.expectEqualStrings("http://collector.example:4317/opentelemetry.proto.collector.logs.v1.LogsService/Export", logs);
}

test "grpc signalUrl: explicit port preserved, custom endpoint used as-is" {
    const testing = std.testing;
    const with_port = try signalUrl(testing.allocator, .{
        .io = std.testing.io,
        .endpoint = "http://127.0.0.1:4317",
        .protocol = .grpc,
    }, "/v1/traces");
    defer testing.allocator.free(with_port);
    try testing.expectEqualStrings("http://127.0.0.1:4317/opentelemetry.proto.collector.trace.v1.TraceService/Export", with_port);

    // append_signal_path = false: the endpoint already names the method.
    const fixed = try signalUrl(testing.allocator, .{
        .io = std.testing.io,
        .endpoint = "http://127.0.0.1:4317/opentelemetry.proto.collector.trace.v1.TraceService/Export",
        .protocol = .grpc,
        .append_signal_path = false,
    }, "/v1/traces");
    defer testing.allocator.free(fixed);
    try testing.expectEqualStrings("http://127.0.0.1:4317/opentelemetry.proto.collector.trace.v1.TraceService/Export", fixed);
}

test "http protocol keeps the 4318 default (no cross-protocol leakage)" {
    const testing = std.testing;
    const url = try signalUrl(testing.allocator, .{
        .io = std.testing.io,
        .endpoint = "http://collector.example",
    }, "/v1/traces");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("http://collector.example:4318/v1/traces", url);

    // An unknown signal path has no gRPC method: fail loud, no silent guess.
    try testing.expectError(
        error.GrpcMethodPathUnknown,
        signalUrl(testing.allocator, .{ .io = std.testing.io, .endpoint = "http://x", .protocol = .grpc }, "/v1/custom"),
    );
}

// ---------------------------------------------------------------------------
// Shared-layer conformance through the public post() entry point.
// ---------------------------------------------------------------------------

test "grpc backend rejects mutual TLS before any network call (shared guard)" {
    const testing = std.testing;
    const config: OtlpExporterConfig = .{
        .io = std.testing.io,
        .protocol = .grpc,
        .tls_config = .{ .cert_file = "/nonexistent/cert.pem", .key_file = "/nonexistent/key.pem" },
    };
    // The guard lives in the shared `postWithPerform` loop and is NOT
    // duplicated here — exercised through the public entry point before any
    // client (or network) exists (REQ-6/SC-12).
    try testing.expectError(
        error.MutualTlsUnsupported,
        post(testing.allocator, testing.allocator, config, "http://127.0.0.1:1/opentelemetry.proto.collector.trace.v1.TraceService/Export", "application/grpc", &.{}, "payload", "trace"),
    );
}

test "grpcResponseFromH2: mapped statuses, message substitution, retry-after, trailers-only" {
    const testing = std.testing;

    // grpc-status 16 + grpc-message + grpc-retry-after (headers merged).
    var headers_unauth = [_]httpx.http2.transport.Header{
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "grpc-status", .value = "16" },
        .{ .name = "grpc-message", .value = "invalid token" },
    };
    var response_unauth = httpx.http2.transport.Response{
        .status = 200,
        .headers = &headers_unauth,
        .body = "",
        .allocator = testing.allocator,
    };
    var mapped = try grpcResponseFromH2(testing.allocator, &response_unauth);
    try testing.expectEqual(std.http.Status.unauthorized, mapped.status);
    try testing.expectEqualStrings("invalid token", mapped.body);
    try testing.expect(mapped.retry_after_millis == null);

    // grpc-status 8 with grpc-retry-after: 2 → retryable + 2000ms.
    var headers_retry = [_]httpx.http2.transport.Header{
        .{ .name = "grpc-status", .value = "8" },
        .{ .name = "grpc-retry-after", .value = "2" },
    };
    var response_retry = httpx.http2.transport.Response{
        .status = 200,
        .headers = &headers_retry,
        .body = "",
        .allocator = testing.allocator,
    };
    testing.allocator.free(mapped.body);
    mapped = try grpcResponseFromH2(testing.allocator, &response_retry);
    try testing.expectEqual(std.http.Status.too_many_requests, mapped.status);
    try testing.expectEqual(@as(?u64, 2000), mapped.retry_after_millis);

    // Unmapped grpc-status 3 (the Datadog 415 probe shape) → synthetic 500.
    var headers_invalid = [_]httpx.http2.transport.Header{
        .{ .name = "grpc-status", .value = "3" },
        .{ .name = "grpc-message", .value = "invalid arg" },
    };
    var response_invalid = httpx.http2.transport.Response{
        .status = 415,
        .headers = &headers_invalid,
        .body = "",
        .allocator = testing.allocator,
    };
    testing.allocator.free(mapped.body);
    mapped = try grpcResponseFromH2(testing.allocator, &response_invalid);
    try testing.expectEqual(std.http.Status.internal_server_error, mapped.status);
    try testing.expectEqualStrings("invalid arg", mapped.body);

    // Trailers-only success: grpc-status 0, no DATA → empty body (SC-20).
    var headers_ok = [_]httpx.http2.transport.Header{
        .{ .name = "grpc-status", .value = "0" },
    };
    var response_ok = httpx.http2.transport.Response{
        .status = 200,
        .headers = &headers_ok,
        .body = "",
        .allocator = testing.allocator,
    };
    testing.allocator.free(mapped.body);
    mapped = try grpcResponseFromH2(testing.allocator, &response_ok);
    try testing.expectEqual(std.http.Status.ok, mapped.status);
    try testing.expectEqual(@as(usize, 0), mapped.body.len);

    // Success with a body frame: de-framed payload lands in Response.body.
    var body_frame = [7]u8{ 0x00, 0x00, 0x00, 0x00, 0x02, 0xBE, 0xEF };
    var response_data = httpx.http2.transport.Response{
        .status = 200,
        .headers = &headers_ok,
        .body = &body_frame,
        .allocator = testing.allocator,
    };
    testing.allocator.free(mapped.body);
    mapped = try grpcResponseFromH2(testing.allocator, &response_data);
    try testing.expectEqual(std.http.Status.ok, mapped.status);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xBE, 0xEF }, mapped.body);

    // No grpc-status at all: raw HTTP status passes through.
    var headers_plain = [_]httpx.http2.transport.Header{};
    var plain_body = [_]u8{ 'b', 'o', 'o', 'm' };
    var response_plain = httpx.http2.transport.Response{
        .status = 500,
        .headers = &headers_plain,
        .body = &plain_body,
        .allocator = testing.allocator,
    };
    testing.allocator.free(mapped.body);
    mapped = try grpcResponseFromH2(testing.allocator, &response_plain);
    try testing.expectEqual(std.http.Status.internal_server_error, mapped.status);
    try testing.expectEqualStrings("boom", mapped.body);
    testing.allocator.free(mapped.body);
}

test "grpcResponseFromH2: missing/unparseable grpc-status on 2xx is a failure, not success" {
    const testing = std.testing;

    // HTTP 200 with NO grpc-status: must NOT report .ok — synthetic 500.
    var headers_none = [_]httpx.http2.transport.Header{
        .{ .name = "content-type", .value = "application/grpc" },
    };
    var response_none = httpx.http2.transport.Response{
        .status = 200,
        .headers = &headers_none,
        .body = "",
        .allocator = testing.allocator,
    };
    var mapped = try grpcResponseFromH2(testing.allocator, &response_none);
    try testing.expectEqual(std.http.Status.internal_server_error, mapped.status);
    testing.allocator.free(mapped.body);

    // Non-numeric grpc-status ("0x0" — hex is not wire-legal) parses as
    // failure: same synthetic 500 path.
    var headers_hex = [_]httpx.http2.transport.Header{
        .{ .name = "grpc-status", .value = "0x0" },
    };
    var response_hex = httpx.http2.transport.Response{
        .status = 200,
        .headers = &headers_hex,
        .body = "",
        .allocator = testing.allocator,
    };
    mapped = try grpcResponseFromH2(testing.allocator, &response_hex);
    try testing.expectEqual(std.http.Status.internal_server_error, mapped.status);
    testing.allocator.free(mapped.body);

    // Empty grpc-status value: same treatment.
    var headers_empty = [_]httpx.http2.transport.Header{
        .{ .name = "grpc-status", .value = "" },
    };
    var response_empty = httpx.http2.transport.Response{
        .status = 200,
        .headers = &headers_empty,
        .body = "",
        .allocator = testing.allocator,
    };
    mapped = try grpcResponseFromH2(testing.allocator, &response_empty);
    try testing.expectEqual(std.http.Status.internal_server_error, mapped.status);
    testing.allocator.free(mapped.body);

    // Non-2xx without grpc-status keeps the raw-HTTP passthrough behavior.
    var headers_404 = [_]httpx.http2.transport.Header{};
    var not_found_body = [_]u8{ 'n', 'o', 't', ' ', 'f', 'o', 'u', 'n', 'd' };
    var response_404 = httpx.http2.transport.Response{
        .status = 404,
        .headers = &headers_404,
        .body = &not_found_body,
        .allocator = testing.allocator,
    };
    mapped = try grpcResponseFromH2(testing.allocator, &response_404);
    try testing.expectEqual(std.http.Status.not_found, mapped.status);
    try testing.expectEqualStrings("not found", mapped.body);
    testing.allocator.free(mapped.body);
}

test "safeHttpStatus clamps out-of-range peer statuses instead of panicking" {
    const testing = std.testing;
    // Valid range converts unchanged.
    try testing.expectEqual(std.http.Status.ok, safeHttpStatus(200));
    try testing.expectEqual(@as(std.http.Status, @fromBackingInt(@intCast(499))), safeHttpStatus(499));
    try testing.expectEqual(std.http.Status.@"continue", safeHttpStatus(100));
    try testing.expect(safeHttpStatus(599) == @as(std.http.Status, @fromBackingInt(@intCast(599))));
    // Out of range (a hostile h2 peer's :status 600/1023+): synthetic 500,
    // no invalid-enum or @intCast panic.
    try testing.expectEqual(std.http.Status.internal_server_error, safeHttpStatus(600));
    try testing.expectEqual(std.http.Status.internal_server_error, safeHttpStatus(1023));
    try testing.expectEqual(std.http.Status.internal_server_error, safeHttpStatus(0));
    try testing.expectEqual(std.http.Status.internal_server_error, safeHttpStatus(65_535));

    // A full 600-status response with no grpc-status maps through the
    // synthetic-500 path end-to-end.
    var headers = [_]httpx.http2.transport.Header{};
    var bogus_body = [_]u8{ 'b', 'o', 'g', 'u', 's' };
    var response = httpx.http2.transport.Response{
        .status = 600,
        .headers = &headers,
        .body = &bogus_body,
        .allocator = testing.allocator,
    };
    const mapped = try grpcResponseFromH2(testing.allocator, &response);
    try testing.expectEqual(std.http.Status.internal_server_error, mapped.status);
    try testing.expectEqualStrings("bogus", mapped.body);
    testing.allocator.free(mapped.body);
}

// Regression guard for the review's use-after-scope finding: httpx's h2
// client stores the TLS session as a POINTER in its Stream union, so the
// connection object must outlive the h2 client — this pins the vendored
// API contract the function-scope hoisting in grpcAttempt relies on.
// (A full h2-over-TLS regression exercise would require a TLS server with
// certificates in the suite; the lifetime fix itself is a source-level
// hoist verified by this structural assertion and by inspection.)
comptime {
    const ti = @typeInfo(httpx.http2.transport.Stream).@"union";
    var tls_field_type: ?type = null;
    for (ti.field_names, ti.field_types) |name, ftype| {
        if (std.mem.eql(u8, name, "tls")) tls_field_type = ftype;
    }
    if (tls_field_type == null) @compileError("httpx http2 Stream lost its tls field — revisit tls_conn lifetime in grpcAttempt");
    if (tls_field_type.? != *httpx.tls.Client.Connection) @compileError("httpx http2 Stream.tls changed from *tls.Client.Connection — revisit tls_conn lifetime in grpcAttempt");
}

// ---------------------------------------------------------------------------
// Loopback h2c scenario test: a real gRPC-shaped exchange over the local
// interface using httpx's own h2 server loop, so the golden framing and
// status mapping are exercised end-to-end at the transport boundary without
// any network dependence.
// ---------------------------------------------------------------------------

const LoopbackGrpcServer = struct {
    fn frameFor(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        return framePayload(allocator, payload);
    }

    fn serve(listener: *std.Io.net.Server, io: std.Io, max_connections: usize) !void {
        // Bounded: each export opens one fresh connection; the loop exits
        // after `max_connections` so `collector.await` can complete.
        var served: usize = 0;
        while (served < max_connections) : (served += 1) {
            serveOne(listener, io, false) catch return;
        }
    }

    fn serveOne(listener: *std.Io.net.Server, io: std.Io, require_auth: bool) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);
        var sock = httpx.tcp.Socket.init(stream, io);
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const ArenaCtx = struct { arena: std.mem.Allocator, require_auth: bool = false };
        var handler_ctx = ArenaCtx{ .arena = arena, .require_auth = require_auth };
        const Handler = struct {
            fn handler(pointer: ?*anyopaque, method: []const u8, path: []const u8, headers: []const httpx.http2.transport.Header, body: []const u8) anyerror!httpx.http2.transport.HandlerResponse {
                _ = method;
                const ctx_ptr: *ArenaCtx = @ptrCast(@alignCast(pointer.?));
                const handler_arena: std.mem.Allocator = ctx_ptr.arena;
                // Validate the gRPC wire shape server-side.
                if (!std.mem.eql(u8, path, "/opentelemetry.proto.collector.trace.v1.TraceService/Export"))
                    return error.UnexpectedPath;
                var has_content_type = false;
                var has_te = false;
                var has_ua = false;
                var has_auth = false;
                for (headers) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "content-type") and std.mem.eql(u8, h.value, "application/grpc")) has_content_type = true;
                    if (std.ascii.eqlIgnoreCase(h.name, "te") and std.mem.eql(u8, h.value, "trailers")) has_te = true;
                    if (std.ascii.eqlIgnoreCase(h.name, "user-agent") and std.mem.eql(u8, h.value, "otel-zig-otlp")) has_ua = true;
                    // Exact match: caller-supplied "X-Auth-Token" must reach
                    // the wire lowercased, not merely case-insensitively.
                    if (std.mem.eql(u8, h.name, "x-auth-token") and std.mem.eql(u8, h.value, "tok-123")) has_auth = true;
                    if (std.mem.indexOfScalar(u8, h.name, 'A') != null or std.mem.indexOfScalar(u8, h.name, 'Z') != null) return error.UppercaseHeaderName;
                }
                if (!has_content_type or !has_te or !has_ua) return error.UnexpectedHeaders;
                if (ctx_ptr.require_auth and !has_auth) return error.MissingAuthHeader;
                // Echo the de-framed payload back in a body frame.
                const payload = try unframePayload(handler_arena, body);
                const framed = try LoopbackGrpcServer.frameFor(handler_arena, payload);
                const trailers = [_]httpx.http2.transport.Header{
                    .{ .name = "grpc-status", .value = "0" },
                };
                return .{ .status = 200, .headers = &trailers, .body = framed };
            }
        };
        try httpx.http2.transport.serveConnection(arena, &sock, Handler.handler, @ptrCast(&handler_ctx));
    }
};

test "grpc e2e loopback via the traces exporter, retry enabled, two exports" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var collector = try io.concurrent(LoopbackGrpcServer.serve, .{ &listener, io, @as(usize, 2) });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    var exporter = otlp_traces.OtlpTraceExporter.init(testing.allocator, .{
        .io = io,
        .endpoint = endpoint,
        .protocol = .grpc,
        .timeout_millis = 1_000,
        .export_timeout_millis = 5_000,
    });
    const spans = [_]otel_sdk.trace.SpanData{testSpan("loopback-exporter-span")};
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, .empty));
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, .empty));
}

test "grpc e2e loopback: framed request, trailer-merged grpc-status, de-framed body" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var collector = try io.concurrent(LoopbackGrpcServer.serve, .{ &listener, io, @as(usize, 1) });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    const url = try signalUrl(testing.allocator, .{
        .io = io,
        .endpoint = endpoint,
        .protocol = .grpc,
        .timeout_millis = 5_000,
        .export_timeout_millis = 5_000,
        .retry_config = .{ .enabled = false },
    }, "/v1/traces");
    defer testing.allocator.free(url);

    const result = try post(testing.allocator, testing.allocator, .{
        .io = io,
        .endpoint = endpoint,
        .protocol = .grpc,
        .timeout_millis = 5_000,
        .export_timeout_millis = 10_000,
        .retry_config = .{ .enabled = false },
    }, url, "application/grpc", &.{}, "grpc-loopback-payload", "trace");
    try testing.expectEqual(ExportResult.success, result);
    try collector.await(io);
}

test "grpc e2e loopback: caller header 'X-Auth-Token' reaches the wire lowercased" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var collector = try io.concurrent(LoopbackGrpcServer.serveOne, .{ &listener, io, true });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    const url = try signalUrl(testing.allocator, .{
        .io = io,
        .endpoint = endpoint,
        .protocol = .grpc,
        .timeout_millis = 5_000,
        .export_timeout_millis = 5_000,
        .retry_config = .{ .enabled = false },
    }, "/v1/traces");
    defer testing.allocator.free(url);

    const caller_headers = [_]std.http.Header{
        .{ .name = "X-Auth-Token", .value = "tok-123" },
    };
    const result = try post(testing.allocator, testing.allocator, .{
        .io = io,
        .endpoint = endpoint,
        .protocol = .grpc,
        .timeout_millis = 5_000,
        .export_timeout_millis = 10_000,
        .retry_config = .{ .enabled = false },
    }, url, "application/grpc", &caller_headers, "grpc-header-case-payload", "trace");
    try testing.expectEqual(ExportResult.success, result);
    try collector.await(io);
}
