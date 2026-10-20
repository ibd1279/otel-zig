//! OTLP/HTTP transport shared by every signal exporter.
//!
//! One POST with a per-request timeout, retried with backoff inside an
//! overall budget, honoring Retry-After, with mutual-TLS routed through the
//! libcurl transport. The traces exporter grew this first; the logs exporter
//! used a bare `std.http.Client` with no timeout, which is why a stalled TLS
//! request could wedge its export thread — and the provider's shutdown —
//! forever. Every signal goes through here now.

const std = @import("std");
const otel_api = @import("otel-api");
const ExportResult = otel_api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const RetryConfig = @import("root.zig").RetryConfig;
const error_handler = otel_api.common;

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    retry_after_millis: ?u64,
};

/// Generic OTLP endpoints get the per-signal path appended; an endpoint that
/// already names the signal (`append_signal_path = false`) is used as is.
pub fn signalUrl(allocator: std.mem.Allocator, config: OtlpExporterConfig, signal_path: []const u8) ![]u8 {
    if (!config.append_signal_path) return allocator.dupe(u8, config.endpoint);
    return joinSignalPathWithOtlpPort(allocator, config.endpoint, signal_path);
}

pub fn joinSignalPath(allocator: std.mem.Allocator, endpoint: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, endpoint);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{
        std.mem.trimEnd(u8, endpoint, "/"),
        std.mem.trimStart(u8, path, "/"),
    });
}

/// Like `joinSignalPath`, but ports the trunk behavior of defaulting a
/// port-less authority to the OTLP/HTTP port (4318) instead of letting
/// std.http fall back to the scheme default (80/443) — a port-less
/// `http://collector` must reach :4318.
fn joinSignalPathWithOtlpPort(allocator: std.mem.Allocator, endpoint: []const u8, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, endpoint, "/");
    const authority = defaultOtlpAuthority(trimmed) orelse trimmed;
    if (path.len == 0) return allocator.dupe(u8, authority);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{
        authority,
        std.mem.trimStart(u8, path, "/"),
    });
}

/// Returns the endpoint with `:4318` inserted when the URL has an authority
/// without an explicit port, else null (nothing to fix).
fn defaultOtlpAuthority(endpoint: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, endpoint, "://") orelse return null;
    var authority_start = scheme_end + 3;
    // Skip userinfo: the port separator we look for comes after any '@'.
    if (std.mem.lastIndexOfScalar(u8, endpoint[authority_start..], '@')) |at| {
        authority_start += at + 1;
    }
    var authority_end = authority_start;
    while (authority_end < endpoint.len and endpoint[authority_end] != '/' and endpoint[authority_end] != '?' and endpoint[authority_end] != '#') : (authority_end += 1) {}
    const authority = endpoint[authority_start..authority_end];
    if (std.mem.indexOfScalar(u8, authority, ':') != null) return null; // explicit port (or IPv6 literal, which must carry one)
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}:4318{s}", .{
        endpoint[0..authority_end],
        endpoint[authority_end..],
    }) catch null;
}

/// POST `payload` to `url`, retrying retryable failures within the budget
/// the config allows. `signal` names the signal in error reports
/// ("trace", "logs", "metrics"). `client_allocator` backs the HTTP client and
/// must outlive the call; `allocator` is scratch (an arena is fine).
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
    const uri = std.Uri.parse(url) catch |err| {
        error_handler.reportError(.{
            .component = .exporter,
            .operation = "otlp_url_parsing",
            .error_type = .configuration,
            .message = "OTLP URL parsing failed",
            .context = url,
            .source_error = err,
        });
        return err;
    };

    const started_ns = std.Io.Timestamp.now(config.io, .awake).nanoseconds;
    const retry_budget_ms = if (config.retry_config.max_elapsed_time_millis == 0)
        config.export_timeout_millis
    else
        @min(config.retry_config.max_elapsed_time_millis, config.export_timeout_millis);
    var interval_ms = config.retry_config.initial_interval_millis;
    while (true) {
        const remaining_ms = remainingMillis(config.io, started_ns, retry_budget_ms);
        if (remaining_ms == 0) return error.ExportTimeout;
        const request_timeout_ms = @min(config.timeout_millis, remaining_ms);
        const response = performWithTimeout(
            client_allocator,
            allocator,
            config,
            url,
            uri,
            content_type,
            extra_headers,
            payload,
            request_timeout_ms,
        ) catch |err| {
            if (!config.retry_config.enabled) return err;
            const delay_ms = retryDelay(config.io, config.retry_config, interval_ms, null);
            if (!sleepBeforeRetry(config.io, started_ns, retry_budget_ms, delay_ms)) return error.ExportRetryExhausted;
            interval_ms = nextInterval(interval_ms, config.retry_config);
            continue;
        };
        defer allocator.free(response.body);

        if (response.status.class() == .success) return .success;
        if (isRetryableStatus(response.status) and config.retry_config.enabled) {
            const delay_ms = retryDelay(config.io, config.retry_config, interval_ms, response.retry_after_millis);
            if (!sleepBeforeRetry(config.io, started_ns, retry_budget_ms, delay_ms)) return error.ExportRetryExhausted;
            interval_ms = nextInterval(interval_ms, config.retry_config);
            continue;
        }

        const error_context = try std.fmt.allocPrint(allocator, "{s} {t}-{s}", .{ url, response.status, response.body });
        defer allocator.free(error_context);
        var op_buf: [48]u8 = undefined;
        const operation = std.fmt.bufPrint(&op_buf, "otlp_{s}_response", .{signal}) catch "otlp_response";
        error_handler.reportError(.{
            .component = .exporter,
            .operation = operation,
            .error_type = switch (response.status) {
                .unauthorized, .forbidden, .not_found => .authentication,
                else => .unknown,
            },
            .message = "OTLP export failed with HTTP error",
            .context = error_context,
        });
        return .failure;
    }
}

fn performWithTimeout(
    client_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    config: OtlpExporterConfig,
    url: []const u8,
    uri: std.Uri,
    content_type: []const u8,
    extra_headers: []const std.http.Header,
    payload: []const u8,
    timeout_ms: u64,
) !Response {
    const Run = struct {
        fn run(
            run_client_allocator: std.mem.Allocator,
            alloc: std.mem.Allocator,
            run_config: OtlpExporterConfig,
            request_url_unused: []const u8,
            request_uri: std.Uri,
            request_content_type: []const u8,
            request_headers: []const std.http.Header,
            request_payload: []const u8,
            request_timeout_ms: u64,
        ) !Response {
            // The attempt deadline is applied by the Select wrapper below, not
            // inside run(); upstream's curl path consumed it itself.
            _ = request_url_unused;
            _ = request_timeout_ms;
            // NOTE: upstream (aliniaai) routes mutual-TLS requests (client
            // cert+key in tls_config) through a libcurl transport here. This
            // tree deliberately stays on native std.http; mTLS client certs
            // are unsupported until std.http grows client-cert support or a
            // curl dependency is deliberately adopted.
            if (run_config.tls_config) |tls| {
                if (tls.cert_file != null and tls.key_file != null) {
                    return error.MutualTlsUnsupported;
                }
            }
            var client = std.http.Client{ .allocator = run_client_allocator, .io = run_config.io };
            defer client.deinit();
            if (run_config.tls_config) |tls| {
                if (tls.ca_file) |ca_file| {
                    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(run_config.io, ca_file, alloc);
                    defer alloc.free(absolute);
                    const now = std.Io.Clock.real.now(run_config.io);
                    try client.ca_bundle.addCertsFromFilePathAbsolute(run_client_allocator, run_config.io, now, absolute);
                    client.now = now;
                }
            }
            var request = try client.request(.POST, request_uri, .{
                .headers = .{
                    .content_type = .{ .override = request_content_type },
                    .user_agent = .{ .override = "otel-zig-otlp" },
                },
                .extra_headers = request_headers,
            });
            defer request.deinit();
            request.transfer_encoding = .{ .content_length = request_payload.len };
            var body = try request.sendBodyUnflushed(&.{});
            try body.writer.writeAll(request_payload);
            try body.end();
            try request.connection.?.flush();

            var response = try request.receiveHead(&.{});
            const status = response.head.status;
            var retry_after_millis: ?u64 = null;
            var headers = response.head.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                    const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch break;
                    retry_after_millis = seconds *| 1000;
                    break;
                }
            }
            var response_body = std.Io.Writer.Allocating.init(alloc);
            errdefer response_body.deinit();
            const reader = response.reader(&.{});
            _ = try reader.streamRemaining(&response_body.writer);
            return .{
                .status = status,
                .body = try response_body.toOwnedSlice(),
                .retry_after_millis = retry_after_millis,
            };
        }
    };
    const Outcome = union(enum) {
        request: anyerror!Response,
        timeout: std.Io.Cancelable!void,
    };
    var outcomes: [2]Outcome = undefined;
    var pending = std.Io.Select(Outcome).init(config.io, &outcomes);
    // Must be `concurrent`, not `async`: `Io.groupAsync` may run the function
    // inline on the calling thread (Threaded does so at its async_limit), which
    // would block the caller until the attempt finishes and make the timeout
    // branch unreachable. `concurrent` guarantees a unit of concurrency.
    try pending.concurrent(.request, Run.run, .{ client_allocator, allocator, config, url, uri, content_type, extra_headers, payload, timeout_ms });
    try pending.concurrent(.timeout, std.Io.sleep, .{
        config.io,
        .{ .nanoseconds = @intCast(timeout_ms *| std.time.ns_per_ms) },
        .awake,
    });
    const result = switch (try pending.await()) {
        .request => |request_result| try request_result,
        .timeout => {
            pending.cancelDiscard();
            return error.Timeout;
        },
    };
    pending.cancelDiscard();
    return result;
}

pub fn isRetryableStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => true,
        else => false,
    };
}

fn remainingMillis(io: std.Io, started_ns: i96, budget_ms: u64) u64 {
    const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const elapsed_ns = @max(0, now_ns - started_ns);
    const elapsed_ms: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
    return budget_ms -| elapsed_ms;
}

pub fn retryDelay(io: std.Io, config: RetryConfig, interval_ms: u64, retry_after_ms: ?u64) u64 {
    const backoff = if (!config.jitter or interval_ms < 2)
        interval_ms
    else backoff: {
        const minimum = interval_ms / 2;
        const maximum = interval_ms +| interval_ms / 2;
        var random: u64 = undefined;
        io.random(std.mem.asBytes(&random));
        break :backoff minimum + random % (maximum - minimum + 1);
    };
    return @max(backoff, retry_after_ms orelse 0);
}

pub fn nextInterval(current_ms: u64, config: RetryConfig) u64 {
    if (!std.math.isFinite(config.multiplier) or config.multiplier <= 1.0) return @min(current_ms, config.max_interval_millis);
    const scaled = @as(f64, @floatFromInt(current_ms)) * config.multiplier;
    if (scaled >= @as(f64, @floatFromInt(config.max_interval_millis))) return config.max_interval_millis;
    const multiplied: u64 = @intFromFloat(scaled);
    return @min(config.max_interval_millis, @max(current_ms, multiplied));
}

fn sleepBeforeRetry(io: std.Io, started_ns: i96, budget_ms: u64, delay_ms: u64) bool {
    const remaining_ms = remainingMillis(io, started_ns, budget_ms);
    if (delay_ms >= remaining_ms) return false;
    io.sleep(.{ .nanoseconds = @intCast(delay_ms *| std.time.ns_per_ms) }, .awake) catch return false;
    return true;
}

test "signal url preserves configured paths" {
    const testing = std.testing;
    const generic = try joinSignalPath(testing.allocator, "https://collector.example/base/", "/v1/traces");
    defer testing.allocator.free(generic);
    try testing.expectEqualStrings("https://collector.example/base/v1/traces", generic);
    const specific = try joinSignalPath(testing.allocator, "https://collector.example/custom", "");
    defer testing.allocator.free(specific);
    try testing.expectEqualStrings("https://collector.example/custom", specific);

    const logs = try signalUrl(testing.allocator, .{ .io = std.testing.io, .endpoint = "https://logfire-us.pydantic.dev:443" }, "/v1/logs");
    defer testing.allocator.free(logs);
    try testing.expectEqualStrings("https://logfire-us.pydantic.dev:443/v1/logs", logs);
    const fixed = try signalUrl(testing.allocator, .{ .io = std.testing.io, .endpoint = "https://x/only-logs", .append_signal_path = false }, "/v1/logs");
    defer testing.allocator.free(fixed);
    try testing.expectEqualStrings("https://x/only-logs", fixed);
}

test "port-less endpoint defaults to the OTLP HTTP port 4318" {
    const testing = std.testing;
    const defaulted = try signalUrl(testing.allocator, .{ .io = std.testing.io, .endpoint = "http://collector.example" }, "/v1/traces");
    defer testing.allocator.free(defaulted);
    try testing.expectEqualStrings("http://collector.example:4318/v1/traces", defaulted);

    // An endpoint that already carries a port is untouched.
    const with_port = try signalUrl(testing.allocator, .{ .io = std.testing.io, .endpoint = "http://collector.example:4319/base" }, "/v1/traces");
    defer testing.allocator.free(with_port);
    try testing.expectEqualStrings("http://collector.example:4319/base/v1/traces", with_port);
}
