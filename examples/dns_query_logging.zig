//! DNS Query Logging Example
//!
//! This example demonstrates OpenTelemetry logging using the new bridge pattern
//! and setup functions. It performs a DNS query for google.com and logs the
//! entire process, including application lifecycle events.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Clean up global providers at program exit
    defer otel_api.provider_registry.unsetAllProviders();

    // Setup global provider with pipeline configuration in one call
    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    const provider = try otel_sdk.logs.setupGlobalProvider(init, .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
        .flowTo(otel_exporters.stream.LogRecordSink.PipelineStep.init(.{ .writer = &stderr.interface }))}, null);
    defer {
        provider.deinit();
        provider.destroy();
    }

    // Get application logger from global registry (now backed by SDK)
    const scope = otel_api.InstrumentationScope{ .name = "dns.query.example", .version = "1.0.0" };
    var app_logger = otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

    // Create execution context
    const ctx = &[_]otel_api.ContextKeyValue{};

    // Log application startup using proper log records
    const startup_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "app.name", .value = .{ .string = "dns-query-example" } })
        .add(.{ .key = "app.version", .value = .{ .string = "1.0.0" } })
        .add(.{ .key = "app.language", .value = .{ .string = "zig" } })
        .add(.{ .key = "event.type", .value = .{ .string = "application.startup" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, startup_attrs);

    app_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS Query Example application starting" }, // body
        startup_attrs, // attributes
        std.Io.Clock.real.now(io), // timestamp
        null, // observed_timestamp
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Perform DNS query with comprehensive logging
    try performDnsQuery(ctx, allocator, io);

    // Log application shutdown
    const shutdown_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "event.type", .value = .{ .string = "application.shutdown" } })
        .add(.{ .key = "app.exit_code", .value = .{ .int = 0 } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, shutdown_attrs);

    app_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS Query Example application shutting down" }, // body
        shutdown_attrs, // attributes
        std.Io.Clock.real.now(io), // timestamp
        null, // observed_timestamp
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );
}

fn performDnsQuery(ctx: []const otel_api.ContextKeyValue, allocator: std.mem.Allocator, io: std.Io) !void {
    const hostname = "google.com";

    // Get DNS operation logger from global registry
    const scope = otel_api.InstrumentationScope{ .name = "dns.resolver" };
    var dns_logger = otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

    // Log DNS query initiation
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "Initiating DNS query for hostname: google.com" }, // body
        null, // attributes
        std.Io.Clock.real.now(io), // timestamp
        null, // observed_timestamp
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Log detailed operation start
    const start_time = std.Io.Clock.real.now(io);
    const dns_start_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
        .add(.{ .key = "operation.name", .value = .{ .string = "dns_query" } })
        .add(.{ .key = "operation.type", .value = .{ .string = "dns_resolution" } })
        .add(.{ .key = "operation.status", .value = .{ .string = "started" } })
        .finish(allocator);
    defer otel_api.AttributeKeyValue.deinitOwnedSlice(allocator, dns_start_attrs);
    dns_logger.emitLogRecord(
        ctx,
        .debug, // severity
        .{ .string = "DNS resolution starting" }, // body
        dns_start_attrs, // attributes
        start_time, // timestamp
        null, // observed_timestamp
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Perform the actual DNS lookup
    const host_name = std.Io.net.HostName.init(hostname) catch |err| {
        return err;
    };
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;

    std.Io.net.HostName.lookup(host_name, io, &lookup_queue, .{
        .port = 80,
        .canonical_name_buffer = &canonical_name_buffer,
    }) catch |err| {
        // Log DNS query failure
        const end_time = std.Io.Clock.real.now(io);
        const duration_ns = @as(i64, @intCast(start_time.durationTo(end_time).nanoseconds));
        const error_attrs = try otel_api.common.AttributeBuilder.init(allocator)
            .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
            .add(.{ .key = "error.type", .value = .{ .string = @errorName(err) } })
            .add(.{ .key = "operation.status", .value = .{ .string = "failed" } })
            .add(.{ .key = "dns.duration_ns", .value = .{ .int = duration_ns } })
            .finish(allocator);
        defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, error_attrs);
        dns_logger.emitLogRecord(
            ctx,
            .@"error", // severity
            .{ .string = "DNS query failed" }, // body
            error_attrs, // attributes
            std.Io.Clock.real.now(io), // timestamp
            null, // observed_timestamp
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
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

    const end_time = std.Io.Clock.real.now(io);
    const duration_ns = @as(i64, @intCast(start_time.durationTo(end_time).nanoseconds));
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Log successful DNS resolution
    const success_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
        .add(.{ .key = "dns.resolved_count", .value = .{ .int = @as(i64, @intCast(addrs.items.len)) } })
        .add(.{ .key = "dns.duration_ns", .value = .{ .int = @as(i64, @intCast(duration_ns)) } })
        .add(.{ .key = "dns.duration_ms", .value = .{ .float = duration_ms } })
        .add(.{ .key = "operation.status", .value = .{ .string = "completed" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, success_attrs);
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS query completed successfully" }, // body
        success_attrs, // attributes
        end_time, // timestamp
        null, // observed_timestamp
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );

    // Log each resolved IP address
    for (addrs.items, 0..) |addr, i| {
        var ip_buf: [64]u8 = undefined;
        var ip_writer = std.Io.Writer.fixed(&ip_buf);
        try addr.format(&ip_writer);
        const ip_str = ip_buf[0..ip_writer.end];

        const ip_attrs = try otel_api.common.AttributeBuilder.init(allocator)
            .add(.{ .key = "dns.hostname", .value = .{ .string = hostname } })
            .add(.{ .key = "dns.resolved_ip", .value = .{ .string = ip_str } })
            .add(.{ .key = "dns.resolution_index", .value = .{ .int = @as(i64, @intCast(i)) } })
            .add(.{ .key = "dns.address_family", .value = .{ .string = "ipv4" } })
            .finish(allocator);
        defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, ip_attrs);
        dns_logger.emitLogRecord(
            ctx,
            .debug, // severity
            .{ .string = "Resolved IP address" }, // body
            ip_attrs, // attributes
            std.Io.Clock.real.now(io), // timestamp
            null, // observed_timestamp
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
    }

    // Log summary statistics
    dns_logger.emitLogRecord(
        ctx,
        .info, // severity
        .{ .string = "DNS resolution summary: google.com resolved to multiple addresses" }, // body
        null, // attributes
        std.Io.Clock.real.now(io), // timestamp
        null, // observed_timestamp
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );
}
