//! DNS Query Logging Example using std.log bridge with Console Output
//!
//! This example demonstrates how existing std.log code can automatically emit
//! OpenTelemetry log records through the std.log bridge, with no changes to
//! existing logging calls. All logs are exported to the console.
//!
//! ## Important Note on OTLP Exporters
//!
//! This example uses console output instead of OTLP to avoid a circular dependency
//! issue. When using OTLP exporters with the std.log bridge, the OTLP exporter's
//! internal debug logging (which uses std.log) can create an infinite loop:
//!
//! std.log -> OTel Bridge -> OTLP Exporter -> std.log.debug -> OTel Bridge -> ...
//!
//! To use OTLP with the std.log bridge in real applications:
//! 1. Disable debug logging in the OTLP exporter, or
//! 2. Configure the bridge to ignore certain scopes, or
//! 3. Use a separate logging system for OTel internal logs

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

// Configure std.log to use OpenTelemetry bridge
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = otel_sdk.std_log_bridge.otelLogFn,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Clean up global providers at program exit
    defer otel_api.provider_registry.unsetAllProviders();

    // Setup global OTel logging provider with console exporter
    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    const provider = try otel_sdk.logs.setupGlobalProvider(
        init,
        .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.stream.LogRecordSink.PipelineStep.init(.{ .writer = &stderr.interface }))},
        null,
    );
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Initialize the std.log bridge
    try otel_sdk.std_log_bridge.init(.{
        .enabled = true,
        .include_scope_attribute = true,
        .instrumentation_scope_name = "dns.query.std_log.example",
        .instrumentation_scope_version = "1.0.0",
    });
    defer otel_sdk.std_log_bridge.deinit();

    // Now all std.log calls will automatically emit OpenTelemetry log records!

    // Log application startup using standard std.log
    std.log.info("DNS Query Example application starting (using std.log bridge)", .{});

    // Perform DNS query with std.log calls
    try performDnsQuery(allocator, io);

    // Log application shutdown
    std.log.info("DNS Query Example application shutting down", .{});

    // Give exporter time to flush
    std.Io.sleep(io, .{ .nanoseconds = 1 * std.time.ns_per_s }, .awake) catch {};
}

fn performDnsQuery(allocator: std.mem.Allocator, io: std.Io) !void {
    const hostname = "google.com";

    // Create scoped logger for DNS operations
    const dns_log = std.log.scoped(.dns_resolver);

    // Log DNS query initiation - this will become an OTel log record automatically
    dns_log.info("Initiating DNS query for hostname: {s}", .{hostname});

    // Log detailed operation start
    dns_log.debug("DNS resolution starting for {s}", .{hostname});

    // Perform the actual DNS lookup
    const host_name = try std.Io.net.HostName.init(hostname);
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;

    std.Io.net.HostName.lookup(host_name, io, &lookup_queue, .{
        .port = 80,
        .canonical_name_buffer = &canonical_name_buffer,
    }) catch |err| {
        // Log DNS query failure using std.log
        dns_log.err("DNS query failed for {s}: {}", .{ hostname, err });
        return err;
    };

    // Collect resolved addresses from the closed queue
    var addrs: std.ArrayList(std.Io.net.IpAddress) = .empty;
    defer addrs.deinit(allocator);

    while (true) {
        const result = lookup_queue.getOneUncancelable(io) catch break;
        switch (result) {
            .address => |addr| try addrs.append(allocator, addr),
            .canonical_name => {},
        }
    }

    // Calculate timing information
    const addr_count = addrs.items.len;

    // Log successful DNS resolution
    dns_log.info("DNS query completed successfully for {s} - resolved {} addresses", .{ hostname, addr_count });

    // Create scoped logger for detailed IP logging
    const ip_log = std.log.scoped(.ip_resolver);

    // Log each resolved IP address
    for (addrs.items, 0..) |addr, i| {
        var ip_buf: [64]u8 = undefined;
        var ip_writer = std.Io.Writer.fixed(&ip_buf);
        try addr.format(&ip_writer);
        const ip_str = ip_buf[0..ip_writer.end];

        ip_log.debug("Resolved IP address #{}: {s} for {s}", .{ i, ip_str, hostname });
    }

    // Use application-specific scoped logger
    const app_log = std.log.scoped(.application);
    app_log.info("DNS resolution summary: {s} resolved to {} addresses", .{ hostname, addr_count });

    // Demonstrate different log levels
    app_log.debug("Debug: DNS lookup operation completed successfully", .{});
    app_log.warn("Warning: This is just a demo warning message", .{});

    // Show error logging (this won't actually error)
    if (addr_count == 0) {
        app_log.err("Error: No IP addresses resolved for {s}", .{hostname});
    }

    // Performance/monitoring scoped logger
    const perf_log = std.log.scoped(.performance);
    perf_log.info("Operation metrics - hostname: {s}, resolved_count: {}, operation: dns_query", .{ hostname, addr_count });

    // Security-related scoped logger
    const security_log = std.log.scoped(.security);
    security_log.debug("DNS query performed for external hostname: {s}", .{hostname});

    // System-level scoped logger
    const system_log = std.log.scoped(.system);
    system_log.info("Network operation completed - DNS resolution for {s}", .{hostname});
}
