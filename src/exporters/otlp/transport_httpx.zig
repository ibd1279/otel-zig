//! httpx.zig-backed OTLP/HTTP transport variant (opt-in via `-Dotlp-httpx`).
//!
//! Call semantics are identical to the default std.http transport: the same
//! `post()` signature, the same `Response` shape, and the same retry layer —
//! this variant routes every attempt through `transport.postWithPerform`,
//! which remains the ONLY retry logic in otel-zig.
//!
//! httpx.zig upstream behaviors that would multiply retries or otherwise
//! diverge from the otel-zig contract are hard-disabled here:
//!   - `Config.maxRetries = 0` — upstream request-level retry is off, so a
//!     retryable server failure produces exactly one HTTP request per
//!     attempt (retry decisions belong solely to `postWithPerform`).
//!   - `retryDelayMs = 0` and an empty `retryStatusCodes` — no residual
//!     upstream retry machinery on any path.
//!   - `followRedirects = false` / `maxRedirects = 0` — an export POST is
//!     never silently re-issued to another URL.
//!   - `eventCallback = null` — no interceptor/hook execution.
//!   - HTTP/1.1 pinned (`http2`/`http3` off) — OTLP/HTTP stays HTTP/1.1.
//!
//! Port-parity with the default backend is inherited for free: endpoint URL
//! construction (`signalUrl`, port-less → :4318 defaulting) and URL-parse
//! error reporting through the error handler both live in `transport.zig`,
//! and this variant re-exports them unchanged.

const std = @import("std");
const httpx = @import("httpx");
const otel_api = @import("otel-api");
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const ExportResult = otel_api.common.ExportResult;

const base = @import("transport.zig");

pub const Response = base.Response;
pub const signalUrl = base.signalUrl;
pub const joinSignalPath = base.joinSignalPath;
pub const isRetryableStatus = base.isRetryableStatus;
pub const retryDelay = base.retryDelay;
pub const nextInterval = base.nextInterval;

/// POST `payload` to `url` via httpx.zig, retrying through the shared
/// otel-zig retry layer only. Signature and return contract match the
/// default std.http transport exactly.
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
    return base.postWithPerform(performHttpx, client_allocator, allocator, config, url, content_type, extra_headers, payload, signal);
}

/// One httpx.zig POST attempt. Issues exactly one HTTP request. The per-
/// attempt deadline is enforced by the shared `attemptWithTimeout` wrapper
/// on `config.io` — httpx's own `timeoutMs` is deliberately NOT set, because
/// its `SO_RCVTIMEO`-based timeout surfaces as EAGAIN inside std.Io's
/// Threaded backend (a programmer-bug panic there) instead of a clean error.
fn performHttpx(
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
    // httpx parses the URL itself; `uri` is kept in the signature for
    // backend parity with the std.http attempt function.
    _ = uri;

    // Mutual TLS is unsupported on every backend: reject a client cert/key
    // configuration before any client (or network) exists (REQ-6/SC-12).
    if (config.tls_config) |tls| {
        if (tls.cert_file != null and tls.key_file != null) {
            return error.MutualTlsUnsupported;
        }
    }

    return base.attemptWithTimeout(config, timeout_ms, httpxAttempt, .{
        client_allocator, allocator, config, url, content_type, extra_headers, payload,
    });
}

fn httpxAttempt(
    client_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    config: OtlpExporterConfig,
    url: []const u8,
    content_type: []const u8,
    extra_headers: []const std.http.Header,
    payload: []const u8,
) anyerror!Response {
    // httpx.zig assumes a blocking (single-threaded) std.Io: it issues
    // socket reads directly instead of through the async readiness model
    // that a concurrent `std.Io.Threaded` requires. Run the client on the
    // dedicated single-threaded instance (the mode httpx's own examples
    // use); the attempt deadline comes from `attemptWithTimeout`, and
    // backoff sleeps keep using the caller's `config.io`.
    const httpx_io = std.Io.Threaded.global_single_threaded.io();
    var client = httpx.Client.init(client_allocator, httpx_io, .{
        // REQ-3: upstream retry, connection-pool retry, and interceptors
        // hard-disabled — single request per attempt.
        .maxRetries = 0,
        .retryDelayMs = 0,
        .retryStatusCodes = &.{},
        .followRedirects = false,
        .maxRedirects = 0,
        .eventCallback = null,
        .http11 = true,
        .http2 = false,
        .http3 = false,
    });
    defer client.deinit();

    var tls_options: ?httpx.TlsOptions = null;
    if (config.tls_config) |tls| {
        if (tls.insecure_skip_verify) {
            tls_options = .{ .verify = .none };
        } else if (tls.ca_file) |ca_file| {
            // Custom CA bundle: load the PEM file for the duration of the
            // request (matches the default backend's ca_file handling).
            const pem = try readPemFile(allocator, config.io, ca_file);
            defer allocator.free(pem);
            tls_options = .{ .verify = .caBundle, .caPem = pem };
        }
    }

    // std.http.Header and httpx.Header are both `{ name: []const u8,
    // value: []const u8 }` with identical layout, so the caller's header
    // slice is passed through without a copy.
    const httpx_headers: []const httpx.Header = @ptrCast(extra_headers);

    var response = try client.fetch(url, .{
        .method = .POST,
        .headers = httpx_headers,
        .body = payload,
        .contentType = content_type,
        .tls = tls_options,
        .followRedirects = false,
        .maxRedirects = 0,
        .http11 = true,
    });
    defer response.deinit();

    var retry_after_millis: ?u64 = null;
    if (response.header("retry-after")) |value| {
        const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t"), 10) catch null;
        if (seconds) |s| retry_after_millis = s *| 1000;
    }

    // The httpx response (and its body) dies with `response.deinit()` above;
    // hand the caller an owned copy, as the std.http backend does.
    const body = try allocator.dupe(u8, response.body);
    errdefer allocator.free(body);
    return .{
        .status = @enumFromInt(response.status),
        .body = body,
        .retry_after_millis = retry_after_millis,
    };
}

fn readPemFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(absolute);
    const file = try std.Io.Dir.cwd().openFile(io, absolute, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const contents = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(contents);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(contents);
    return contents;
}

test "httpx backend rejects mutual TLS before any network call" {
    const testing = std.testing;
    const uri = try std.Uri.parse("http://127.0.0.1:1/v1/traces");
    const config: OtlpExporterConfig = .{
        .io = std.testing.io,
        .tls_config = .{ .cert_file = "/nonexistent/cert.pem", .key_file = "/nonexistent/key.pem" },
    };
    try testing.expectError(
        error.MutualTlsUnsupported,
        performHttpx(testing.allocator, testing.allocator, config, "http://127.0.0.1:1/v1/traces", uri, "application/x-protobuf", &.{}, "payload", 1000),
    );
}

test "httpx backend mirrors the default backend's retryable status set" {
    const testing = std.testing;
    for ([_]std.http.Status{ .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout }) |status| {
        try testing.expect(isRetryableStatus(status));
    }
    try testing.expect(!isRetryableStatus(.not_found));
}

// ---------------------------------------------------------------------------
// Verify-phase scenario checks (SC-6..SC-10, SC-1 e2e probe).
// These run against a local HTTP receiver that counts requests, so
// "exactly one request per attempt" (no upstream retry multiplication,
// REQ-3) is asserted at the transport boundary.
// ---------------------------------------------------------------------------

const ScenarioServer = struct {
    count: usize = 0,
    first_arrival_ns: i96 = 0,
    second_arrival_ns: i96 = 0,

    /// Responds `statuses[index]` to the index-th request; `retry_after` is
    /// sent only on the request whose index is in `retry_after_indices`.
    /// Records per-request arrival timestamps in `self`.
    fn receiveSequence(
        self: *ScenarioServer,
        listener: *std.Io.net.Server,
        io: std.Io,
        statuses: []const std.http.Status,
        retry_after: ?[]const u8,
    ) !void {
        for (statuses) |status| {
            var stream = try listener.accept(io);
            defer stream.close(io);
            if (self.count == 0) self.first_arrival_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
            if (self.count == 1) self.second_arrival_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
            self.count += 1;
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            const body_reader = request.readerExpectNone(&.{});
            var discard = std.Io.Writer.Discarding.init(&.{});
            _ = try body_reader.streamRemaining(&discard.writer);
            const extra: []const std.http.Header = if (retry_after) |ra|
                &.{.{ .name = "retry-after", .value = ra }}
            else
                &.{};
            try request.respond("", .{ .status = status, .keep_alive = false, .extra_headers = extra });
        }
    }

    /// Accepts one request, drains it, and never responds (SC-9 stall).
    fn receiveAndStallForever(listener: *std.Io.net.Server, io: std.Io) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        const body_reader = request.readerExpectNone(&.{});
        var discard = std.Io.Writer.Discarding.init(&.{});
        _ = try body_reader.streamRemaining(&discard.writer);
        try io.sleep(.{ .nanoseconds = 60 * std.time.ns_per_s }, .awake);
    }

    /// Accepts one request, captures target/content-type/body, answers 200.
    fn receiveCapture(listener: *std.Io.net.Server, io: std.Io, capture: *E2eCapture) !void {
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
                if (header.value.len > capture.content_type.len) return error.HeaderTooLong;
                @memcpy(capture.content_type[0..header.value.len], header.value);
                capture.content_type_len = header.value.len;
            }
        }
        const body_reader = request.readerExpectNone(&.{});
        var body_writer = std.Io.Writer.fixed(&capture.body);
        _ = try body_reader.streamRemaining(&body_writer);
        capture.body_len = body_writer.buffered().len;
        try request.respond("", .{ .status = .ok, .keep_alive = false });
    }
};

const E2eCapture = struct {
    target: [256]u8 = undefined,
    target_len: usize = 0,
    body: [64 * 1024]u8 = undefined,
    body_len: usize = 0,
    content_type: [64]u8 = undefined,
    content_type_len: usize = 0,

    fn targetSlice(self: *const E2eCapture) []const u8 {
        return self.target[0..self.target_len];
    }

    fn bodySlice(self: *const E2eCapture) []const u8 {
        return self.body[0..self.body_len];
    }
};

fn scenarioConfig(io: std.Io, retry: transport_root.RetryConfig) transport_root.OtlpExporterConfig {
    return .{
        .io = io,
        .endpoint = "http://127.0.0.1:1",
        .timeout_millis = 1_000,
        .export_timeout_millis = 500,
        .retry_config = retry,
    };
}

const transport_root = @import("root.zig");

test "httpx SC-6: a retryable failure issues exactly one request per otel-zig attempt" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock_error_handler = otel_api.common.MockErrorHandler.init(testing.allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var server_state: ScenarioServer = .{};
    // One retryable 503, then success: the shared retry layer must retry once
    // and httpx must not add its own retry on top (exactly 2 requests total).
    var collector = try io.concurrent(ScenarioServer.receiveSequence, .{
        &server_state, &listener, io, &[_]std.http.Status{ .service_unavailable, .ok }, @as(?[]const u8, null),
    });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1/traces", .{listener.socket.address.getPort()});
    var config = scenarioConfig(io, .{
        .initial_interval_millis = 5,
        .max_interval_millis = 5,
        .max_elapsed_time_millis = 500,
        .jitter = false,
    });
    config.endpoint = endpoint;
    const result = try post(testing.allocator, testing.allocator, config, endpoint, "application/x-protobuf", &.{}, "payload", "trace");
    try testing.expectEqual(ExportResult.success, result);
    try collector.await(io);
    try testing.expectEqual(@as(usize, 2), server_state.count);
}

test "httpx SC-6: retry disabled means exactly one request on a retryable failure" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock_error_handler = otel_api.common.MockErrorHandler.init(testing.allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var server_state: ScenarioServer = .{};
    var collector = try io.concurrent(ScenarioServer.receiveSequence, .{
        &server_state, &listener, io, &[_]std.http.Status{.service_unavailable}, @as(?[]const u8, null),
    });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1/traces", .{listener.socket.address.getPort()});
    var config = scenarioConfig(io, .{ .enabled = false });
    config.endpoint = endpoint;
    const result = try post(testing.allocator, testing.allocator, config, endpoint, "application/x-protobuf", &.{}, "payload", "trace");
    try testing.expectEqual(ExportResult.failure, result);
    try collector.await(io);
    try testing.expectEqual(@as(usize, 1), server_state.count);
}

test "httpx SC-7: a deterministic failure returns immediately without upstream retry" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock_error_handler = otel_api.common.MockErrorHandler.init(testing.allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    // Unreachable host (connection refused) with retries disabled: the
    // transport must return the failure immediately — no upstream-issued
    // retry attempt (httpx maxRetries=0), no hang.
    const config: transport_root.OtlpExporterConfig = scenarioConfig(io, .{ .enabled = false });
    const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const result = post(testing.allocator, testing.allocator, config, config.endpoint, "application/x-protobuf", &.{}, "payload", "trace");
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - started;
    try testing.expectError(error.ConnectFailed, result);
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
}

test "httpx SC-8: the delay before the next attempt honors Retry-After" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock_error_handler = otel_api.common.MockErrorHandler.init(testing.allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var server_state: ScenarioServer = .{};
    // 503 with `Retry-After: 1`, then success. The configured backoff (5ms,
    // jitter off) is far below 1s, so the gap between requests proves the
    // server-provided value wins.
    var collector = try io.concurrent(ScenarioServer.receiveSequence, .{
        &server_state, &listener, io, &[_]std.http.Status{ .service_unavailable, .ok }, @as(?[]const u8, "1"),
    });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1/traces", .{listener.socket.address.getPort()});
    var config = scenarioConfig(io, .{
        .initial_interval_millis = 5,
        .max_interval_millis = 5,
        .max_elapsed_time_millis = 5_000,
        .jitter = false,
    });
    // The 1s Retry-After must fit within the budget, so raise the export
    // timeout above the helper's 500ms default.
    config.endpoint = endpoint;
    config.export_timeout_millis = 10_000;
    const result = try post(testing.allocator, testing.allocator, config, endpoint, "application/x-protobuf", &.{}, "payload", "trace");
    try testing.expectEqual(ExportResult.success, result);
    try collector.await(io);
    try testing.expectEqual(@as(usize, 2), server_state.count);
    const gap_ns = server_state.second_arrival_ns - server_state.first_arrival_ns;
    try testing.expect(gap_ns >= 950 * std.time.ns_per_ms);
}

test "httpx SC-9: budget expiring mid-attempt returns ExportRetryExhausted, never a hang" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock_error_handler = otel_api.common.MockErrorHandler.init(testing.allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var collector = try io.concurrent(ScenarioServer.receiveAndStallForever, .{ &listener, io });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1/traces", .{listener.socket.address.getPort()});
    // Total budget (300ms) far below the per-attempt timeout (10s): the
    // stalled attempt is abandoned at the budget and the export returns,
    // never hangs.
    var config = scenarioConfig(io, .{
        .initial_interval_millis = 50,
        .max_interval_millis = 50,
        .max_elapsed_time_millis = 300,
        .jitter = false,
    });
    config.endpoint = endpoint;
    config.timeout_millis = 10_000;
    const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const result = post(testing.allocator, testing.allocator, config, endpoint, "application/x-protobuf", &.{}, "payload", "trace");
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - started;
    try testing.expectError(error.ExportRetryExhausted, result);
    try testing.expect(elapsed < 5 * std.time.ns_per_s);
}

test "httpx SC-10: a 404 is non-retryable and reported as failure" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock_error_handler = otel_api.common.MockErrorHandler.init(testing.allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var server_state: ScenarioServer = .{};
    var collector = try io.concurrent(ScenarioServer.receiveSequence, .{
        &server_state, &listener, io, &[_]std.http.Status{.not_found}, @as(?[]const u8, null),
    });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1/traces", .{listener.socket.address.getPort()});
    var config: transport_root.OtlpExporterConfig = scenarioConfig(io, .{
        .initial_interval_millis = 5,
        .max_interval_millis = 5,
        .max_elapsed_time_millis = 500,
        .jitter = false,
    });
    config.endpoint = endpoint;
    const result = try post(testing.allocator, testing.allocator, config, endpoint, "application/x-protobuf", &.{}, "payload", "trace");
    try testing.expectEqual(ExportResult.failure, result);
    try collector.await(io);
    // Retries enabled, yet a 404 gets exactly one request: non-retryable.
    try testing.expectEqual(@as(usize, 1), server_state.count);
    try testing.expect(mock_error_handler.errorCount() >= 1);
}

test "httpx SC-1 e2e: one OTLP traces batch exports through the httpx backend" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mock_error_handler = otel_api.common.MockErrorHandler.init(testing.allocator);
    defer mock_error_handler.deinit();
    otel_api.common.setMockErrorHandler(&mock_error_handler);
    defer otel_api.common.clearMockErrorHandler();

    var listener = (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true }) catch unreachable;
    defer listener.deinit(io);
    var capture: E2eCapture = .{};
    var collector = try io.concurrent(ScenarioServer.receiveCapture, .{ &listener, io, &capture });
    defer _ = collector.cancel(io) catch {};

    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1/traces", .{listener.socket.address.getPort()});
    // The exporter stays backend-unaware: with -Dotlp-httpx this call goes
    // through the httpx-backed transport (REQ-1/SC-1).
    var exporter = otlp_traces.OtlpTraceExporter.init(testing.allocator, .{
        .endpoint = endpoint,
        .io = io,
        .transport = .http_protobuf,
        .append_signal_path = false,
        .timeout_millis = 1_000,
        .retry_config = .{ .enabled = false },
    });
    const spans = [_]otel_sdk.trace.SpanData{testSpan("e2e-httpx-span")};
    try testing.expectEqual(ExportResult.success, exporter.exportSpans(&spans, .empty));
    try collector.await(io);

    try testing.expectEqualStrings("/v1/traces", capture.targetSlice());
    try testing.expectEqualStrings("application/x-protobuf", capture.content_type[0..capture.content_type_len]);
    try testing.expect(capture.body_len > 2);
    try testing.expect(std.mem.indexOf(u8, capture.bodySlice(), "e2e-httpx-span") != null);
}

const otel_sdk = @import("otel-sdk");
const otlp_traces = @import("traces.zig");

fn testSpan(name: []const u8) otel_sdk.trace.SpanData {
    return .{
        .scope = .{ .name = "httpx-scenario-test" },
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
