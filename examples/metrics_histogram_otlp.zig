//! Comprehensive OpenTelemetry Metrics OTLP Export Example
//!
//! This example demonstrates all OpenTelemetry instrument types with OTLP export:
//! - Counter: Monotonic values that only increase
//! - UpDownCounter: Values that can increase or decrease
//! - Gauge: Point-in-time measurements
//! - Histogram: Distribution of values with buckets
//!
//! It simulates an HTTP server with various endpoints and system metrics,
//! exporting all telemetry data via OTLP to a backend like Jaeger or an
//! OpenTelemetry Collector.
//!
//! To run this example, you need an OTLP-compatible backend running.
//! For example:
//! - OpenTelemetry Collector: docker run -p 4318:4318 otel/opentelemetry-collector:latest
//! - Jaeger with OTLP support: docker run -p 4318:4318 jaegertracing/all-in-one:latest

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const concrete_provider = try otel_sdk.metrics.setupGlobalProvider(
        init,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init(.{ .io = io })
            .flowTo(otel_exporters.otlp.OtlpMetricExporter.PipelineStep.init(.{ .io = io }))},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get a meter
    const scope = otel_api.InstrumentationScope{ .name = "example.comprehensive.otlp", .version = "1.0.0" };
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    std.debug.print("=== Comprehensive OpenTelemetry Metrics OTLP Export Demo ===\n\n", .{});

    // ========================================================================
    // Create all instrument types
    // ========================================================================

    // COUNTERS: Monotonic values that only increase
    const request_counter = try meter.createCounter(
        i64,
        "foo.bar.bas.request_count",
        "Total number of HTTP requests processed",
        "1",
        null,
    );

    const bytes_sent_counter = try meter.createCounter(
        i64,
        "foo.bar.bas.bytes_sent",
        "Total bytes sent",
        "bytes",
        null,
    );

    const request_duration_total = try meter.createCounter(
        f64,
        "foo.bar.bas.request_duration_total",
        "Total time spent processing requests",
        "seconds",
        null,
    );

    // UP-DOWN COUNTERS: Values that can increase or decrease
    const active_requests = try meter.createUpDownCounter(
        i64,
        "foo.bar.bas.active_requests",
        "Number of currently active HTTP requests",
        "1",
        null,
    );

    const connection_pool_size = try meter.createUpDownCounter(
        i64,
        "foo.bar.bas.connection_pool_size",
        "Current number of connections in the pool",
        "1",
        null,
    );

    // GAUGES: Point-in-time measurements
    const memory_usage = try meter.createGauge(
        f64,
        "foo.bar.bas.memory_usage",
        "Current memory usage in megabytes",
        "MB",
        null,
    );

    const cpu_usage = try meter.createGauge(
        f64,
        "foo.bar.bas.cpu_usage",
        "Current CPU usage percentage",
        "percent",
        null,
    );

    const disk_free_space = try meter.createGauge(
        f64,
        "foo.bar.bas.disk_free_space",
        "Available disk space in gigabytes",
        "GB",
        null,
    );

    // HISTOGRAMS: Distribution of values with buckets
    const latency_histogram = try meter.createHistogram(
        f64,
        "foo.bar.bas.request_duration",
        "Distribution of request durations",
        "milliseconds",
        null,
    );

    const request_size_histogram = try meter.createHistogram(
        i64,
        "foo.bar.bas.request.size",
        "Distribution of request sizes",
        "bytes",
        null,
    );

    const response_size_histogram = try meter.createHistogram(
        i64,
        "foo.bar.bas.response.size",
        "Distribution of HTTP response body sizes",
        "bytes",
        null,
    );

    const db_query_duration_histogram = try meter.createHistogram(
        f64,
        "foo.bar.bas.db_query.duration",
        "Distribution of database query durations",
        "ms",
        null,
    );

    const ctx = &[_]otel_api.ContextKeyValue{};

    // ========================================================================
    // Simulate HTTP server activity with all instrument types
    // ========================================================================

    std.debug.print("Starting HTTP server simulation...\n", .{});

    // Simulate initial system state
    connection_pool_size.add(ctx, 10, &.{}); // Start with 10 connections
    std.debug.print("  Connection pool initialized: 10 connections\n", .{});

    // Simulate API endpoint requests
    std.debug.print("\nProcessing API requests...\n", .{});

    const api_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "http.method", .value = .{ .string = "GET" } })
        .add(.{ .key = "http.route", .value = .{ .string = "/api/users" } })
        .add(.{ .key = "http.status_code", .value = .{ .int = 200 } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, api_attrs);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        // Request starts - increment active requests
        active_requests.add(ctx, 1, api_attrs);

        // Simulate processing
        const duration = 12.5 + @as(f64, @floatFromInt(i)) * 3.2;
        const request_size: i64 = 256 + @as(i64, @intCast(i)) * 128;
        const response_size: i64 = 2048 + @as(i64, @intCast(i)) * 2048;

        // Record histogram measurements
        latency_histogram.record(ctx, duration, api_attrs);
        request_size_histogram.record(ctx, request_size, api_attrs);
        response_size_histogram.record(ctx, response_size, api_attrs);

        // Record counter measurements
        request_counter.add(ctx, 1, api_attrs);
        request_duration_total.add(ctx, duration, api_attrs);
        bytes_sent_counter.add(ctx, response_size, api_attrs);

        // Request ends - decrement active requests
        active_requests.add(ctx, -1, api_attrs);

        std.debug.print("  API request {}: {d:.1}ms, {d} bytes req, {d} bytes resp\n", .{ i + 1, duration, request_size, response_size });
    }

    // Simulate static file requests (typically faster)
    std.debug.print("\nProcessing static file requests...\n", .{});

    const static_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "http.method", .value = .{ .string = "GET" } })
        .add(.{ .key = "http.route", .value = .{ .string = "/static/*" } })
        .add(.{ .key = "http.status_code", .value = .{ .int = 200 } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, static_attrs);

    i = 0;
    while (i < 3) : (i += 1) {
        active_requests.add(ctx, 1, static_attrs);

        const duration = 2.0 + @as(f64, @floatFromInt(i)) * 0.5;
        const request_size: i64 = 64 + @as(i64, @intCast(i)) * 32;
        const response_size: i64 = 32768 + @as(i64, @intCast(i)) * 16384;

        latency_histogram.record(ctx, duration, static_attrs);
        request_size_histogram.record(ctx, request_size, static_attrs);
        response_size_histogram.record(ctx, response_size, static_attrs);

        request_counter.add(ctx, 1, static_attrs);
        request_duration_total.add(ctx, duration, static_attrs);
        bytes_sent_counter.add(ctx, response_size, static_attrs);

        active_requests.add(ctx, -1, static_attrs);

        std.debug.print("  Static request {}: {d:.1}ms, {d} bytes req, {d} bytes resp\n", .{ i + 1, duration, request_size, response_size });
    }

    // Simulate database queries (variable latency)
    std.debug.print("\nProcessing database queries...\n", .{});

    const db_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "http.method", .value = .{ .string = "POST" } })
        .add(.{ .key = "http.route", .value = .{ .string = "/api/query" } })
        .add(.{ .key = "http.status_code", .value = .{ .int = 200 } })
        .add(.{ .key = "db.system", .value = .{ .string = "postgresql" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, db_attrs);

    i = 0;
    while (i < 4) : (i += 1) {
        active_requests.add(ctx, 1, db_attrs);

        // Simulate connection pool growth under load
        if (i == 2) {
            connection_pool_size.add(ctx, 5, &.{});
            std.debug.print("    Connection pool expanded by 5 connections\n", .{});
        }

        const http_duration = 125.0 + @as(f64, @floatFromInt(i)) * 50.0;
        const db_duration = 89.0 + @as(f64, @floatFromInt(i)) * 35.0;
        const request_size: i64 = 1024 + @as(i64, @intCast(i)) * 512;
        const response_size: i64 = 8192 + @as(i64, @intCast(i)) * 8192;

        // Record both HTTP and DB metrics
        latency_histogram.record(ctx, http_duration, db_attrs);

        const db_query_attrs = try otel_api.common.AttributeBuilder.init(allocator)
            .add(.{ .key = "db.system", .value = .{ .string = "postgresql" } })
            .add(.{ .key = "db.operation", .value = .{ .string = "SELECT" } })
            .finish(allocator);
        defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, db_query_attrs);

        db_query_duration_histogram.record(ctx, db_duration, db_query_attrs);

        request_size_histogram.record(ctx, request_size, db_attrs);
        response_size_histogram.record(ctx, response_size, db_attrs);

        request_counter.add(ctx, 1, db_attrs);
        request_duration_total.add(ctx, http_duration, db_attrs);
        bytes_sent_counter.add(ctx, response_size, db_attrs);

        active_requests.add(ctx, -1, db_attrs);

        std.debug.print("  DB query {}: HTTP {d:.1}ms, DB {d:.1}ms, {d} bytes req, {d} bytes resp\n", .{ i + 1, http_duration, db_duration, request_size, response_size });
    }

    // Simulate some error responses
    std.debug.print("\nProcessing error responses...\n", .{});

    const error_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "http.method", .value = .{ .string = "GET" } })
        .add(.{ .key = "http.route", .value = .{ .string = "/api/invalid" } })
        .add(.{ .key = "http.status_code", .value = .{ .int = 404 } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, error_attrs);

    i = 0;
    while (i < 2) : (i += 1) {
        active_requests.add(ctx, 1, error_attrs);

        const duration = 0.8 + @as(f64, @floatFromInt(i)) * 0.4;
        const response_size: i64 = 256;

        latency_histogram.record(ctx, duration, error_attrs);
        request_size_histogram.record(ctx, 0, error_attrs);
        response_size_histogram.record(ctx, response_size, error_attrs);

        request_counter.add(ctx, 1, error_attrs);
        request_duration_total.add(ctx, duration, error_attrs);
        bytes_sent_counter.add(ctx, response_size, error_attrs);

        active_requests.add(ctx, -1, error_attrs);

        std.debug.print("  Error response {}: {d:.1}ms\n", .{ i + 1, duration });
    }

    // ========================================================================
    // Record system metrics (gauges)
    // ========================================================================

    std.debug.print("\nRecording system metrics...\n", .{});

    // Simulate memory usage.
    const simulated_memory: f64 = 2048.5;
    const memory_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "memory.type", .value = .{ .string = "heap" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, memory_attrs);

    memory_usage.record(ctx, simulated_memory, memory_attrs);
    std.debug.print("  Memory usage: {d:.2} MiB (simulated)\n", .{simulated_memory});

    // CPU usage
    const cpu_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "cpu.core", .value = .{ .string = "all" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, cpu_attrs);

    cpu_usage.record(ctx, 45.2, cpu_attrs);
    std.debug.print("  CPU usage: 45.2%\n", .{});

    // Disk space
    const disk_attrs = try otel_api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "disk.device", .value = .{ .string = "/dev/disk1" } })
        .add(.{ .key = "disk.mount_point", .value = .{ .string = "/" } })
        .finish(allocator);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, disk_attrs);

    disk_free_space.record(ctx, 128.7, disk_attrs);
    std.debug.print("  Disk free space: 128.7 GiB\n", .{});

    // ========================================================================
    // Export metrics to OTLP
    // ========================================================================

    std.debug.print("\nFlushing metrics to OTLP endpoint...\n", .{});

    // Force flush to ensure metrics are sent
    const flush_result = concrete_provider.forceFlush(5000);
    if (flush_result == .success) {
        std.debug.print("✅ Metrics successfully exported to OTLP endpoint!\n", .{});
    } else {
        std.debug.print("❌ Failed to export metrics. Is your OTLP endpoint running?\n", .{});
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Successfully demonstrated all OpenTelemetry instrument types:\n", .{});
    std.debug.print("✅ Counter: 3 instruments (requests, bytes, duration total)\n", .{});
    std.debug.print("✅ UpDownCounter: 2 instruments (active requests, connection pool)\n", .{});
    std.debug.print("✅ Gauge: 3 instruments (memory, CPU, disk space)\n", .{});
    std.debug.print("✅ Histogram: 4 instruments (latency, request/response sizes, DB queries)\n", .{});
    std.debug.print("\nTotal HTTP requests simulated: 14\n", .{});
    std.debug.print("- API endpoints: 5 requests\n", .{});
    std.debug.print("- Static files: 3 requests\n", .{});
    std.debug.print("- Database queries: 4 requests\n", .{});
    std.debug.print("- Error responses: 2 requests\n", .{});
    std.debug.print("\nAll metrics exported via OTLP for analysis! 🚀\n", .{});
}
