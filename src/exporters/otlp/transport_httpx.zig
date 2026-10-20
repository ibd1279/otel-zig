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
