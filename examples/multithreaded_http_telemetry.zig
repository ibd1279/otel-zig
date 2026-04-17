//! Comprehensive Multi-threaded OpenTelemetry Example
//!
//! This example demonstrates advanced OpenTelemetry features in a multi-threaded
//! HTTP client/server simulation, showcasing:
//!
//! ## Features Demonstrated:
//! - **Batch Processing**: Logs, metrics, and traces with different intervals
//! - **Multi-threading**: Context propagation between threads
//! - **Metric Views**: Transform instruments with attribute filtering and renaming
//! - **Observable Gauges**: Async metrics collection (uptime tracking)
//! - **Span Events**: Add timestamped events to spans
//! - **Span Links**: Link spans across different traces
//! - **W3C Trace Context**: HTTP header propagation
//! - **Rich Telemetry**: Structured logging, histograms, counters
//!
//! The example simulates an HTTP client making requests to a server, with full
//! observability instrumentation showing real-world telemetry patterns.
//!
//! Metrics output:
//! - `numbers_read` - counter
//! - `numbers_detailed - histogram view of number_values
//! - `numbers_by_thread - histogram view of number_values
//! - `app_uptime` - observable gauge

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");
const otel_semconv = @import("otel-semconv");

const print = std.debug.print;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

// Configuration for the telemetry example
const ExporterType = enum {
    console,
    otlp,

    fn fromString(str: []const u8) ?ExporterType {
        if (std.mem.eql(u8, str, "console")) return .console;
        if (std.mem.eql(u8, str, "otlp")) return .otlp;
        return null;
    }
};

const Config = struct {
    exporter_type: ExporterType,
    duration_seconds: u32,
    sampling_ratio: f64,
};

// Shared state between threads
const SharedState = struct {
    allocator: Allocator,
    io: std.Io,
    should_stop: std.atomic.Value(bool),
    server_address: []const u8,
    server_port: u16,
    start_ns: i96, // For uptime calculation
    error_count: std.atomic.Value(u32), // Track errors across threads

    const Self = @This();

    pub fn init(allocator: Allocator, io: std.Io, port: u16) Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .should_stop = std.atomic.Value(bool).init(false),
            .server_address = "127.0.0.1",
            .server_port = port,
            .start_ns = std.Io.Clock.real.now(io).nanoseconds,
            .error_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .monotonic);
    }

    pub fn shouldStop(self: *Self) bool {
        return self.should_stop.load(.monotonic);
    }

    pub fn getUptimeNs(self: *Self) u64 {
        return @intCast(std.Io.Clock.real.now(self.io).nanoseconds - self.start_ns);
    }

    pub fn incrementErrorCount(self: *Self) void {
        _ = self.error_count.fetchAdd(1, .monotonic);
    }

    pub fn getErrorCount(self: *Self) u32 {
        return self.error_count.load(.monotonic);
    }
};

// Helper function to build W3C traceparent header
fn buildTraceparentHeader(span_context: otel_api.trace.Span.Context, buffer: []u8) ![]u8 {
    var trace_hex_buf: [32]u8 = undefined;
    var span_hex_buf: [16]u8 = undefined;

    const trace_hex = span_context.traceIdHex(&trace_hex_buf);
    const span_hex = span_context.spanIdHex(&span_hex_buf);

    return std.fmt.bufPrint(buffer, "00-{s}-{s}-{x:0>2}", .{
        trace_hex,
        span_hex,
        @as(u8, if (span_context.isSampled()) 0x01 else 0x00),
    });
}

// Helper function to parse W3C traceparent header
fn parseTraceparentHeader(header_value: []const u8) ?otel_api.trace.Span.Context {
    if (header_value.len != 55) return null; // 00-32-16-02 format

    // Parse version (should be 00)
    if (!std.mem.eql(u8, header_value[0..2], "00")) return null;
    if (header_value[2] != '-') return null;

    // Parse trace ID (32 hex chars)
    const trace_id_str = header_value[3..35];
    if (header_value[35] != '-') return null;
    var trace_id_bytes: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&trace_id_bytes, trace_id_str) catch return null;

    // Parse span ID (16 hex chars)
    const span_id_str = header_value[36..52];
    if (header_value[52] != '-') return null;
    var span_id_bytes: [8]u8 = undefined;
    _ = std.fmt.hexToBytes(&span_id_bytes, span_id_str) catch return null;

    // Parse flags (2 hex chars)
    const flags_str = header_value[53..55];
    const flags_byte = std.fmt.parseInt(u8, flags_str, 16) catch return null;

    return otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId{ .bytes = trace_id_bytes },
        .span_id = otel_api.common.SpanId{ .bytes = span_id_bytes },
        .trace_flags = flags_byte,
        .trace_state = null,
        .is_remote = true,
    };
}

// HTTP context for simulated requests
const HttpContext = struct {
    traceparent: ?[]const u8,
    tracestate: ?[]const u8,
    num1: u16,
    num2: u16,
    result: u64,
    status_code: u16,

    fn deinit(self: *HttpContext) void {
        _ = self; // Placeholder for cleanup if needed
    }
};

// Observable gauge callback for uptime tracking
fn uptimeCallback(allocator: std.mem.Allocator, result: *otel_api.metrics.ObservableResult(i64), state: *anyopaque) void {
    const shared_state: *SharedState = @ptrCast(@alignCast(state));
    const uptime_ns = shared_state.getUptimeNs();
    result.observe(allocator, @intCast(uptime_ns), &[_]otel_api.common.AttributeKeyValue{
        .{ .key = "component", .value = .{ .string = "application" } },
    });
}

fn numberReaderThread(shared_state: *SharedState, config: Config, io: std.Io) !void {
    // Get instrumentation scope for the reader thread
    const reader_scope = otel_api.InstrumentationScope{ .name = "multithreaded-http-telemetry/number-reader", .version = "1.0.0" };
    var logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(reader_scope);
    var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(reader_scope);
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(reader_scope);

    // Create metrics instruments
    const numbers_counter = try meter.createCounter(
        i64,
        "numbers_read",
        "Total numbers read from random source",
        "1",
        null,
    );

    // Create histogram with 16-bit boundaries (0-65535, 16 buckets)
    // Note: This histogram will be split into multiple views by the provider
    var boundary_buffer: [15]f64 = undefined; // 16 buckets = 15 boundaries
    for (0..15) |i| {
        boundary_buffer[i] = @floatFromInt((i + 1) * (65536 / 16));
    }
    const boundaries = boundary_buffer[0..];

    const numbers_histogram = try meter.createHistogram(
        f64,
        "number_values",
        "Histogram of 16-bit numbers read",
        "1",
        .{ .explicit_bucket_boundaries = boundaries },
    );

    // Create observable uptime gauge with callback
    const obs_uptime_gauge = try meter.createObservableGauge(
        i64,
        "app_uptime",
        "Application uptime in nanoseconds",
        "ns",
        null,
        &[_]otel_api.metrics.TypeErasedCallback(i64){},
    );
    _ = try obs_uptime_gauge.registerCallback(
        SharedState,
        uptimeCallback,
        shared_state,
    );

    logger.emitLog(
        &.{},
        .info,
        "Number reader thread started",
        null,
        null, // event_name
    );

    const loop_start_ns = std.Io.Clock.real.now(io).nanoseconds;
    const duration_ns: u64 = @as(u64, config.duration_seconds) * std.time.ns_per_s;
    var prng = std.Random.DefaultPrng.init(@intCast(loop_start_ns - shared_state.start_ns));
    const rand = prng.random();
    var iteration: u32 = 0;
    var previous_span_context: ?otel_api.trace.Span.Context = null;

    while (!shared_state.shouldStop()) {
        const now_ns = std.Io.Clock.real.now(io).nanoseconds;
        if (@as(u64, @intCast(now_ns - loop_start_ns)) >= duration_ns) break;
        iteration += 1;

        // Generate two random 16-bit numbers
        const num1: u16 = rand.int(u16);
        const num2: u16 = rand.int(u16);

        // Record metrics - these will be processed by multiple views
        const ctx = &[_]otel_api.context.ContextKeyValue{};
        numbers_counter.add(ctx, 2, &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "source", .value = .{ .string = "random" } },
            .{ .key = otel_semconv.trace.THREAD_NAME, .value = .{ .string = "reader" } },
        });
        numbers_histogram.record(ctx, @floatFromInt(num1), &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "number_type", .value = .{ .string = "num1" } },
            .{ .key = otel_semconv.trace.THREAD_NAME, .value = .{ .string = "reader" } },
        });
        numbers_histogram.record(ctx, @floatFromInt(num2), &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "number_type", .value = .{ .string = "num2" } },
            .{ .key = otel_semconv.trace.THREAD_NAME, .value = .{ .string = "reader" } },
        });

        // Create root span for this operation
        var root_span = try tracer.startSpan("process_number_pair", .{
            .kind = .client,
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "iteration", .value = .{ .int = @intCast(iteration) } },
                .{ .key = "num1", .value = .{ .int = @intCast(num1) } },
                .{ .key = "num2", .value = .{ .int = @intCast(num2) } },
                .{ .key = otel_semconv.trace.THREAD_NAME, .value = .{ .string = "reader" } },
            },
            .links = if (previous_span_context) |prev_ctx|
                &[_]otel_api.trace.Span.Link{.{
                    .span_context = prev_ctx,
                    .attributes = &[_]otel_api.common.AttributeKeyValue{
                        .{ .key = "link.type", .value = .{ .string = "follows_from" } },
                        .{ .key = "previous.iteration", .value = .{ .int = @intCast(iteration - 1) } },
                    },
                }}
            else
                &[_]otel_api.trace.Span.Link{},
        }, ctx);
        defer {
            root_span.end(.{});
            root_span.deinit();
        }

        // Add event to mark number generation and link status
        try root_span.addEvent(.{
            .name = "numbers_generated",
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "num1", .value = .{ .int = @intCast(num1) } },
                .{ .key = "num2", .value = .{ .int = @intCast(num2) } },
                .{ .key = "generation.method", .value = .{ .string = "crypto_random" } },
                .{ .key = "has_previous_span", .value = .{ .bool = previous_span_context != null } },
                .{ .key = "is_first_iteration", .value = .{ .bool = iteration == 1 } },
            },
        });

        // Save current span context for next iteration's link
        previous_span_context = root_span.getSpanContext();

        // Prepare HTTP request with trace context
        const url = try std.fmt.allocPrint(shared_state.allocator, "http://{s}:{d}/multiply/{d}/{d}", .{ shared_state.server_address, shared_state.server_port, num1, num2 });
        defer shared_state.allocator.free(url);

        // Create child span for HTTP request
        const child_ctx = try otel_api.trace.trace_context.withActiveSpanContext(shared_state.allocator, ctx, root_span.getSpanContext());
        defer otel_api.ContextKeyValue.deinitOwnedSlice(shared_state.allocator, @constCast(child_ctx));
        var http_span = try tracer.startSpan("http_request", .{
            .kind = .client,
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = otel_semconv.trace.HTTP_METHOD, .value = .{ .string = otel_semconv.trace.HttpMethodValues.GET } },
                .{ .key = otel_semconv.trace.HTTP_URL, .value = .{ .string = url } },
                .{ .key = otel_semconv.trace.HTTP_SCHEME, .value = .{ .string = "http" } },
                .{ .key = otel_semconv.trace.NET_PEER_NAME, .value = .{ .string = shared_state.server_address } },
                .{ .key = otel_semconv.trace.NET_PEER_PORT, .value = .{ .int = @intCast(shared_state.server_port) } },
            },
        }, child_ctx);
        defer {
            http_span.end(.{});
            http_span.deinit();
        }

        // Add event for request start
        try http_span.addEvent(.{
            .name = "request.start",
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = otel_semconv.trace.HTTP_TARGET, .value = .{ .string = url } },
            },
        });

        // Build traceparent header
        var traceparent_buffer: [55]u8 = undefined;
        const traceparent = try buildTraceparentHeader(http_span.getSpanContext(), &traceparent_buffer);
        var http_context = HttpContext{
            .traceparent = traceparent,
            .tracestate = "example-client=reader-thread",
            .num1 = num1,
            .num2 = num2,
            .result = 0,
            .status_code = 0,
        };
        defer http_context.deinit();

        // Call the server.
        processHttpRequest(child_ctx, &http_context, &logger, shared_state.allocator, io);

        // Increment error count if server returned an error
        if (http_context.status_code >= 400) {
            shared_state.incrementErrorCount();
        }

        // Add response event (status code will be set by server processing)
        try http_span.addEvent(.{
            .name = "response.received",
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = otel_semconv.trace.HTTP_STATUS_CODE, .value = .{ .int = @intCast(http_context.status_code) } },
                .{ .key = "response.result", .value = .{ .int = @intCast(http_context.result) } },
            },
        });

        // Handle response based on status code from server
        if (http_context.status_code == 500) {
            // Server returned error due to overflow
            http_span.setStatus(.{ .code = .@"error", .description = "Server error: result overflow" });
            http_span.setAttribute(.{ .key = otel_semconv.trace.HTTP_STATUS_CODE, .value = .{ .int = 500 } });

            // Add error event
            try http_span.addEvent(.{
                .name = "error",
                .attributes = &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = otel_semconv.exception.EXCEPTION_TYPE, .value = .{ .string = "server_error" } },
                    .{ .key = otel_semconv.exception.EXCEPTION_MESSAGE, .value = .{ .string = "Server returned 500: multiplication overflow" } },
                    .{ .key = "num1_value", .value = .{ .int = @intCast(num1) } },
                    .{ .key = "num2_value", .value = .{ .int = @intCast(num2) } },
                    .{ .key = "server_result", .value = .{ .int = @intCast(http_context.result) } },
                },
            });

            logger.emitLog(
                &.{},
                .@"error",
                "Request failed: server returned error due to overflow",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "num1", .value = .{ .int = @intCast(num1) } },
                    .{ .key = "num2", .value = .{ .int = @intCast(num2) } },
                    .{ .key = "server_result", .value = .{ .int = @intCast(http_context.result) } },
                    .{ .key = "status_code", .value = .{ .int = @intCast(http_context.status_code) } },
                    .{ .key = "iteration", .value = .{ .int = @intCast(iteration) } },
                },
                null, // event_name
            );
        } else {
            // Server returned success
            http_span.setStatus(.{ .code = .ok, .description = "Request successful" });
            http_span.setAttribute(.{ .key = otel_semconv.trace.HTTP_STATUS_CODE, .value = .{ .int = 200 } });
            http_span.setAttribute(.{ .key = "result", .value = .{ .int = @intCast(http_context.result) } });

            logger.emitLog(
                &.{},
                .info,
                "Request completed successfully",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "num1", .value = .{ .int = @intCast(num1) } },
                    .{ .key = "num2", .value = .{ .int = @intCast(num2) } },
                    .{ .key = "result", .value = .{ .int = @intCast(http_context.result) } },
                    .{ .key = "iteration", .value = .{ .int = @intCast(iteration) } },
                    .{ .key = "response_time_category", .value = .{ .string = if (http_context.result < 1000) "fast" else "slow" } },
                },
                null, // event_name
            );
        }
    }

    logger.emitLog(
        &.{},
        .info,
        "Number reader thread completed",
        &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "total_iterations", .value = .{ .int = @intCast(iteration) } },
        },
        null, // event_name
    );
}

fn httpServerThread(shared_state: *SharedState, config: Config, io: std.Io) !void {
    _ = config; // Config not used in server thread, only in reader thread

    std.debug.print("http server thread starting\n", .{});
    defer std.debug.print("http server thread shutdown\n", .{});

    const root_resource = try otel_sdk.resource.detectResource(shared_state.allocator, io);
    defer root_resource.deinitOwned(shared_state.allocator);

    // This would normally happen in the detect resources and would come from on env var.
    const core_resource = try otel_sdk.resource.Resource.initOwnedMerge(shared_state.allocator, root_resource, .{
        .attributes = &.{ .{ .key = otel_semconv.SERVICE_NAME, .value = .{ .string = "multithreaded_http_telemetry/server" } }, .{ .key = otel_semconv.SERVICE_VERSION, .value = .{ .string = "1.0.0.0" } } },
    });
    defer core_resource.deinitOwned(shared_state.allocator);

    var logger_provider = otel_sdk.logs.LoggerProvider.init(
        shared_state.allocator,
        io,
        try otel_sdk.resource.Resource.initOwned(shared_state.allocator, core_resource),
    );
    logger_provider.default_min_severity = .warn;
    defer logger_provider.deinit();
    {
        const exporter = try shared_state.allocator.create(otel_exporters.otlp.OtlpLogExporter);
        errdefer shared_state.allocator.destroy(exporter);
        exporter.* = otel_exporters.otlp.OtlpLogExporter.init(shared_state.allocator, .{ .io = io });
        errdefer exporter.deinit();
        const processor = try otel_sdk.logs.BatchLogRecordProcessor.init(io, shared_state.allocator, exporter.logRecordExporter(), 5000, 5000, try otel_sdk.resource.Resource.initOwned(shared_state.allocator, core_resource));
        errdefer processor.deinit();
        try processor.start();
        try logger_provider.registerProcessor(processor.logProcessor());
    }

    var meter_provider = otel_sdk.metrics.MeterProvider.init(
        shared_state.allocator,
        io,
        try otel_sdk.resource.Resource.initOwned(shared_state.allocator, core_resource),
    );
    defer meter_provider.deinit();
    {
        const exporter = try shared_state.allocator.create(otel_exporters.otlp.OtlpMetricExporter);
        errdefer shared_state.allocator.destroy(exporter);
        exporter.* = otel_exporters.otlp.OtlpMetricExporter.init(shared_state.allocator, .{ .io = io });
        errdefer exporter.deinit();
        const reader = try shared_state.allocator.create(otel_sdk.metrics.PeriodicReader);
        errdefer shared_state.allocator.destroy(reader);
        reader.* = try otel_sdk.metrics.PeriodicReader.init(shared_state.allocator, io, exporter.metricsExporter(), 5000);
        errdefer reader.deinit();
        try reader.start();
        try meter_provider.registerReader(reader.reader());
    }
    var tracer_provider = otel_sdk.trace.TracerProvider.init(
        shared_state.allocator,
        io,
        try otel_sdk.resource.Resource.initOwned(shared_state.allocator, core_resource),
        otel_sdk.trace.createDefaultIdGenerator(),
        otel_sdk.trace.samplers.parentBased(otel_sdk.trace.samplers.traceIdRatioBased(0.5)),
    );
    defer tracer_provider.deinit();
    {
        const exporter = try shared_state.allocator.create(otel_exporters.otlp.OtlpTraceExporter);
        errdefer shared_state.allocator.destroy(exporter);
        exporter.* = otel_exporters.otlp.OtlpTraceExporter.init(shared_state.allocator, .{ .io = io });
        errdefer exporter.deinit();
        const processor = try shared_state.allocator.create(otel_sdk.trace.BatchSpanProcessor);
        errdefer shared_state.allocator.destroy(processor);
        processor.* = otel_sdk.trace.BatchSpanProcessor.init(io, shared_state.allocator, exporter.spanExporter(), .{
            .export_interval_ms = 5000,
            .max_queue_size = 5000,
        });
        errdefer processor.deinit();
        try processor.start();
        try tracer_provider.registerProcessor(processor.spanProcessor());
    }

    // Get instrumentation scope for the server thread
    const server_scope = otel_api.InstrumentationScope{ .name = "multiply", .version = "1.0.0" };
    var logger = try logger_provider.getLoggerWithScope(server_scope);

    logger.emitLog(
        &.{},
        .info,
        "HTTP server thread started",
        &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "address", .value = .{ .string = shared_state.server_address } },
            .{ .key = "port", .value = .{ .int = @intCast(shared_state.server_port) } },
        },
        null, // event_name
    );

    var request_id: u32 = 0;

    // Create and bind socket
    const address = std.Io.net.IpAddress.parseIp4(shared_state.server_address, shared_state.server_port) catch |err| {
        logger.emitLog(
            &.{},
            .@"error",
            "Failed to parse server address",
            &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "address", .value = .{ .string = shared_state.server_address } },
                .{ .key = "port", .value = .{ .int = @intCast(shared_state.server_port) } },
                .{ .key = "error", .value = .{ .string = @errorName(err) } },
            },
            null, // event_name
        );
        return;
    };

    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        logger.emitLog(
            &.{},
            .@"error",
            "Failed to bind to server address",
            &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "address", .value = .{ .string = shared_state.server_address } },
                .{ .key = "port", .value = .{ .int = @intCast(shared_state.server_port) } },
                .{ .key = "error", .value = .{ .string = @errorName(err) } },
            },
            null, // event_name
        );
        return;
    };
    defer server.deinit(io);

    logger.emitLog(
        &.{},
        .info,
        "HTTP server listening for connections",
        &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "address", .value = .{ .string = shared_state.server_address } },
            .{ .key = "port", .value = .{ .int = @intCast(shared_state.server_port) } },
        },
        null, // event_name
    );

    const tracer = try tracer_provider.getTracerWithScope(server_scope);
    const meter = try meter_provider.getMeterWithScope(server_scope);
    const request_instrument = try meter.createCounter(i64, "product_request_count", null, "1", null);

    // Accept connections loop
    while (!shared_state.shouldStop()) {
        // Set a timeout for accept to periodically check shouldStop
        const stream = server.accept(io) catch |err| switch (err) {
            error.WouldBlock => {
                std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms * 10 }, .awake) catch {};
                continue;
            },
            else => {
                logger.emitLog(
                    &.{},
                    .@"error",
                    "Failed to accept connection",
                    &[_]otel_api.common.AttributeKeyValue{
                        .{ .key = "error", .value = .{ .string = @errorName(err) } },
                    },
                    null, // event_name
                );
                continue;
            },
        };
        defer stream.close(io);

        request_id += 1;
        request_instrument.add(&.{}, 1, &.{});

        logger.emitLog(
            &.{},
            .debug,
            "Accepted new connection",
            &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "request_id", .value = .{ .int = @intCast(request_id) } },
                .{ .key = "client_address", .value = .{ .string = "remote address" } },
            },
            null, // event_name
        );

        // Read and parse the HTTP request
        var read_buffer = [_]u8{0} ** 4096;
        var reader = stream.reader(io, &read_buffer);
        var write_buffer = [_]u8{0} ** 512;
        var writer = stream.writer(io, &write_buffer);
        var http_server = std.http.Server.init(
            &reader.interface,
            &writer.interface,
        );
        var request = http_server.receiveHead() catch |err| {
            logger.emitLog(
                &.{},
                .@"error",
                "Failed to receive HTTP request head",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "error", .value = .{ .string = @errorName(err) } },
                    .{ .key = "request_id", .value = .{ .int = @intCast(request_id) } },
                },
                null,
            );
            continue;
        };

        // Extract W3C trace context headers
        var ctx_builder = otel_api.ContextBuilder.init(shared_state.allocator);
        var traceparent_header: ?[]const u8 = null;
        var tracestate_header: ?[]const u8 = null;

        // Look for traceparent and tracestate headers in request headers
        var header_iterator = request.iterateHeaders();
        while (header_iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "traceparent")) {
                traceparent_header = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "tracestate")) {
                tracestate_header = header.value;
            }
        }

        if (traceparent_header) |tp_value| {
            const extracted_span_context = parseTraceparentHeader(tp_value);
            if (extracted_span_context) |span_context| {
                const with_state = if (tracestate_header) |ts|
                    span_context.withTraceState(ts)
                else
                    span_context;
                ctx_builder = ctx_builder.add(
                    .{ .key = otel_api.trace.context_keys.remote_span_context_key.key_id, .value = otel_api.trace.context_keys.remote_span_context_key.wrapValue(with_state.asRemote()) },
                );
            }
        }

        const ctx = ctx_builder.finish(shared_state.allocator) catch |err| {
            logger.emitLog(
                &.{},
                .@"error",
                "Failed to build context from traceparent header",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "error", .value = .{ .string = @errorName(err) } },
                    .{ .key = "request_id", .value = .{ .int = @intCast(request_id) } },
                    .{ .key = "has_traceparent", .value = .{ .bool = traceparent_header != null } },
                },
                null,
            );
            continue;
        };
        defer otel_api.ContextKeyValue.deinitOwnedSlice(shared_state.allocator, ctx);

        var span = try tracer.startSpan("GET /multiply/{}/{}", otel_api.trace.Span.StartOptions{
            .kind = .server,
        }, ctx);
        defer {
            span.end(null);
            span.deinit();
        }
        if (tracestate_header) |ts| {
            span.setAttribute(.{ .key = "w3c.tracestate", .value = .{ .string = ts } });
        }

        logger.emitLog(
            ctx,
            .debug,
            "Processing HTTP request with trace context",
            &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "request_id", .value = .{ .int = @intCast(request_id) } },
                .{ .key = "method", .value = .{ .string = @tagName(request.head.method) } },
                .{ .key = "path", .value = .{ .string = request.head.target } },
                .{ .key = "has_traceparent", .value = .{ .bool = traceparent_header != null } },
                .{ .key = "tracestate", .value = .{ .string = tracestate_header orelse "" } },
            },
            null,
        );

        // Parse URL path to extract a and b parameters
        // Expected format: /multiply/{a}/{b}
        const path = request.head.target;

        // Split path by '/' to get components
        var path_parts = std.mem.splitScalar(u8, path, '/');
        _ = path_parts.next(); // Skip empty first part

        const operation = path_parts.next() orelse {
            try request.respond("Invalid path format", .{ .status = .bad_request });
            span.setStatus(.{ .code = .@"error", .description = "Invalid path format" });
            continue;
        };

        if (!std.mem.eql(u8, operation, "multiply")) {
            try request.respond("Invalid path format", .{ .status = .bad_request });
            span.setStatus(.{ .code = .@"error", .description = "Invalid operation" });
            continue;
        }

        const a_str = path_parts.next() orelse {
            try request.respond("Missing parameter", .{ .status = .bad_request });
            span.setStatus(.{ .code = .@"error", .description = "Missing parameter a" });
            continue;
        };

        const b_str = path_parts.next() orelse {
            try request.respond("Missing parameter", .{ .status = .bad_request });
            span.setStatus(.{ .code = .@"error", .description = "Missing parameter b" });
            continue;
        };

        // Parse a and b as u16 numbers
        const a = std.fmt.parseInt(u16, a_str, 10) catch {
            try request.respond("Invalid number for a", .{ .status = .bad_request });
            span.setStatus(.{ .code = .@"error", .description = "Invalid number for parameter a" });
            continue;
        };

        const b = std.fmt.parseInt(u16, b_str, 10) catch {
            try request.respond("Invalid number for b", .{ .status = .bad_request });
            span.setStatus(.{ .code = .@"error", .description = "Invalid number for parameter b" });
            continue;
        };

        // Multiply the numbers
        const product: u64 = @as(u64, a) * @as(u64, b);

        // Check if product is >= 2^31
        const max_value: u64 = (1 << 31) + 0x7FFFFFF; // 2^31 + some more buffer
        if (product >= max_value) {
            try request.respond("Product too large", .{ .status = .bad_request });
            span.setStatus(.{ .code = .@"error", .description = "Product exceeds limits" });
            span.setAttribute(.{ .key = "product", .value = .{ .int = @intCast(product) } });
            span.setAttribute(.{ .key = "limit", .value = .{ .int = @intCast(max_value) } });
            continue;
        }

        // Return 200 with the product
        var response_buffer: [64]u8 = undefined;
        const response_body = try std.fmt.bufPrint(response_buffer[0..], "{}", .{product});

        try request.respond(response_body, .{ .status = .bad_request });
        span.setStatus(.{ .code = .ok, .description = "Multiplication successful" });
        span.setAttribute(.{ .key = "a", .value = .{ .int = @intCast(a) } });
        span.setAttribute(.{ .key = "b", .value = .{ .int = @intCast(b) } });
        span.setAttribute(.{ .key = "product", .value = .{ .int = @intCast(product) } });
    }

    logger.emitLog(
        &.{},
        .info,
        "HTTP server thread completed",
        &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "total_requests", .value = .{ .int = @intCast(request_id) } },
        },
        null, // event_name
    );
}

fn printUsage() void {
    print("Usage: multithreaded_http_telemetry [exporter] [duration] [sampling_ratio]\n", .{});
    print("\n", .{});
    print("Arguments:\n", .{});
    print("  exporter        Exporter type: 'console' (default) or 'otlp'\n", .{});
    print("  duration        Test duration in seconds (default: 5)\n", .{});
    print("  sampling_ratio  Trace sampling ratio 0.0-1.0 (default: 1.0 = 100%%)\n", .{});
    print("\n", .{});
    print("Examples:\n", .{});
    print("  multithreaded_http_telemetry                    # Console, 5s, 100% sampling\n", .{});
    print("  multithreaded_http_telemetry console            # Console, 5s, 100% sampling\n", .{});
    print("  multithreaded_http_telemetry otlp               # OTLP, 5s, 100% sampling\n", .{});
    print("  multithreaded_http_telemetry console 30         # Console, 30s, 100% sampling\n", .{});
    print("  multithreaded_http_telemetry otlp 60 0.1        # OTLP, 60s, 10% sampling\n", .{});
    print("  multithreaded_http_telemetry console 15 0.5     # Console, 15s, 50% sampling\n", .{});
    print("\n", .{});
}

fn parseArgs(allocator: Allocator, process_args: std.process.Args) !Config {
    var it = try process_args.iterateAllocator(allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (it.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }
    defer for (args.items) |arg| allocator.free(arg);

    var config = Config{
        .exporter_type = .console, // Default to console
        .duration_seconds = 5, // Default to 5 seconds
        .sampling_ratio = 1.0, // Default to 100% sampling
    };

    if (args.items.len > 4) {
        print("❌ Error: Too many arguments\n\n", .{});
        printUsage();
        std.process.exit(1);
    }

    // Handle help option
    if (args.items.len >= 2 and (std.mem.eql(u8, args.items[1], "--help") or std.mem.eql(u8, args.items[1], "-h"))) {
        printUsage();
        std.process.exit(0);
    }

    // Parse exporter type (first argument)
    if (args.items.len >= 2) {
        if (ExporterType.fromString(args.items[1])) |exporter_type| {
            config.exporter_type = exporter_type;
        } else {
            print("❌ Error: Invalid exporter type '{s}'. Use 'console' or 'otlp'\n\n", .{args.items[1]});
            printUsage();
            std.process.exit(1);
        }
    }

    // Parse duration (second argument)
    if (args.items.len >= 3) {
        config.duration_seconds = std.fmt.parseInt(u32, args.items[2], 10) catch {
            print("❌ Error: Invalid duration '{s}'. Must be a positive integer\n\n", .{args.items[2]});
            printUsage();
            std.process.exit(1);
        };

        if (config.duration_seconds == 0) {
            print("❌ Error: Duration must be greater than 0 seconds\n\n", .{});
            printUsage();
            std.process.exit(1);
        }
    }

    // Parse sampling ratio (third argument)
    if (args.items.len >= 4) {
        config.sampling_ratio = std.fmt.parseFloat(f64, args.items[3]) catch {
            print("❌ Error: Invalid sampling ratio '{s}'. Must be a number between 0.0 and 1.0\n\n", .{args.items[3]});
            printUsage();
            std.process.exit(1);
        };

        if (config.sampling_ratio < 0.0 or config.sampling_ratio > 1.0) {
            print("❌ Error: Sampling ratio must be between 0.0 and 1.0, got {d}\n\n", .{config.sampling_ratio});
            printUsage();
            std.process.exit(1);
        }
    }

    return config;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Parse command-line arguments
    const config = try parseArgs(allocator, init.minimal.args);

    print("🚀 Starting Comprehensive Multi-threaded OpenTelemetry Example\n", .{});
    print("=" ** 70 ++ "\n", .{});
    print("📊 Features: Views, Observable Gauges, Events, Links, Batch Processing\n", .{});
    print("🔧 Configuration: {s} exporter, {} seconds duration\n", .{ @tagName(config.exporter_type), config.duration_seconds });
    print("🎯 Sampling: TraceIdRatioBasedSampler with {d:.1} sampling ratio\n", .{config.sampling_ratio});
    print("=" ** 70 ++ "\n", .{});

    // Setup logs provider with batch processor and custom resource
    const log_resource = try createServiceResource(allocator, io);
    var stderr_buffer = [_]u8{0} ** 1024;
    const log_provider = switch (config.exporter_type) {
        .console => blk: {
            var stderr = otel_exporters.console.initStream(io, true, &stderr_buffer);
            break :blk try setupCustomLogProvider(
                allocator,
                io,
                log_resource,
                .{otel_sdk.logs.BatchLogRecordProcessor.PipelineStep.init(.{
                    .io = io,
                    .export_interval_ms = 5000,
                    .max_queue_size = 5000,
                    .resource = log_resource,
                }).flowTo(otel_exporters.stream.LogRecordSink.PipelineStep.init(.{ .writer = &stderr.interface }))},
            );
        },
        .otlp => blk: {
            break :blk try setupCustomLogProvider(
                allocator,
                io,
                log_resource,
                .{otel_sdk.logs.BatchLogRecordProcessor.PipelineStep.init(.{
                    .io = io,
                    .export_interval_ms = 5000,
                    .max_queue_size = 5000,
                    .resource = log_resource,
                }).flowTo(otel_exporters.otlp.OtlpLogExporter.PipelineStep.init(.{ .io = io }))},
            );
        },
    };
    defer {
        log_provider.deinit();
        log_provider.destroy();
    }

    // Define metric views to transform instruments
    const metric_views = .{
        // View 1: Create a simplified version of number_values with only thread attribute
        otel_sdk.metrics.View{
            .instrument_selector = .{ .name = "number_values" },
            .name = "numbers_by_thread",
            .description = "Number values grouped by thread only",
            .attribute_allowed_keys = &[_][]const u8{otel_semconv.trace.THREAD_NAME},
        },

        // View 2: Create a detailed version with both attributes
        otel_sdk.metrics.View{
            .instrument_selector = .{ .name = "number_values" },
            .name = "numbers_detailed",
            .description = "Detailed number values with all attributes",
            .attribute_allowed_keys = &[_][]const u8{ "number_type", otel_semconv.trace.THREAD_NAME },
        },

        // View 3: Drop debug metrics in production
        otel_sdk.metrics.View{
            .instrument_selector = .{ .name = "debug.*" },
            .aggregation_override = .drop,
        },
    };

    // Setup metrics provider with periodic reader, views, and custom resource
    const metric_provider = switch (config.exporter_type) {
        .console => blk: {
            var stderr_buffer2 = [_]u8{0} ** 1024;
            var stderr2 = std.Io.File.stderr().writer(io, &stderr_buffer2);
            break :blk try setupCustomMetricProvider(
                allocator,
                io,
                .{otel_sdk.metrics.PeriodicReader.PipelineStep.init(.{ .io = io, .interval_ms = 5000 }) // Export metrics every 5 seconds
                    .flowTo(otel_exporters.stream.MetricDataSink.PipelineStep.init(.{ .writer = &stderr2.interface }))},
                metric_views,
            );
        },
        .otlp => try setupCustomMetricProvider(
            allocator,
            io,
            .{otel_sdk.metrics.PeriodicReader.PipelineStep.init(.{ .io = io, .interval_ms = 5000 }) // Export metrics every 5 seconds
                .flowTo(otel_exporters.otlp.OtlpMetricExporter.PipelineStep.init(.{ .io = io }))},
            metric_views,
        ),
    };
    defer {
        metric_provider.deinit();
        metric_provider.destroy();
    }

    // Setup traces provider with batch processor and custom sampling
    const trace_provider = switch (config.exporter_type) {
        .console => blk: {
            var stderr_buffer3 = [_]u8{0} ** 1024;
            var stderr3 = std.Io.File.stderr().writer(io, &stderr_buffer3);
            break :blk try setupCustomTraceProvider(
                allocator,
                io,
                config.sampling_ratio,
                .{otel_sdk.trace.BatchSpanProcessor.PipelineStep.init(.{
                    .io = io,
                    .export_interval_ms = 5000, // Export spans every 3 seconds
                    .max_queue_size = 5000, // Queue up to 50 spans
                }).flowTo(otel_exporters.stream.SpanDataSink.PipelineStep.init(.{ .writer = &stderr3.interface }))},
            );
        },
        .otlp => try setupCustomTraceProvider(
            allocator,
            io,
            config.sampling_ratio,
            .{otel_sdk.trace.BatchSpanProcessor.PipelineStep.init(.{
                .io = io,
                .export_interval_ms = 5000, // Export spans every 3 seconds
                .max_queue_size = 5000, // Queue up to 50 spans
            }).flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(.{ .io = io }))},
        ),
    };
    defer {
        trace_provider.deinit();
        trace_provider.destroy();
    }

    print("✅ OpenTelemetry providers configured\n", .{});
    print("   📝 Logs: Batch export every 2s\n", .{});
    print("   📊 Metrics: Periodic collection every 5s + 3 views\n", .{});
    print("   🔍 Traces: Batch export every 3s + events + links + {d:.1} sampling\n", .{config.sampling_ratio});

    // Create shared state
    var shared_state = SharedState.init(allocator, io, 8080);

    // Log startup
    const main_scope = otel_api.InstrumentationScope{ .name = "multithreaded-http-telemetry/main", .version = "1.0.0" };
    var main_logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(main_scope);

    main_logger.emitLog(
        &.{},
        .info,
        "Application starting with enhanced telemetry",
        &[_]otel_api.common.AttributeKeyValue{
            .{ .key = otel_semconv.SERVICE_VERSION, .value = .{ .string = "1.0.0" } },
            .{ .key = "server.port", .value = .{ .int = @intCast(shared_state.server_port) } },
            .{ .key = "features.views", .value = .{ .bool = true } },
            .{ .key = "features.observable_gauges", .value = .{ .bool = true } },
            .{ .key = "features.span_events", .value = .{ .bool = true } },
            .{ .key = "features.span_links", .value = .{ .bool = true } },
        },
        null, // event_name
    );

    print("🌐 Starting HTTP server simulation on port {d}\n", .{shared_state.server_port});
    print("🔢 Starting number reader client\n", .{});
    print("⏱️  Observable uptime gauge will track application runtime\n", .{});
    print("⏰ Running for {} seconds...\n\n", .{config.duration_seconds});

    // Start both threads
    const server_thread = try Thread.spawn(.{}, httpServerThread, .{ &shared_state, config, io });
    const reader_thread = try Thread.spawn(.{}, numberReaderThread, .{ &shared_state, config, io });

    // Wait for reader thread to complete (it stops after configured duration)
    reader_thread.join();

    // Stop server thread
    shared_state.stop();
    server_thread.join();

    // Get final error count
    const final_error_count = shared_state.getErrorCount();

    // Log final error count with appropriate severity
    const error_log_level = if (final_error_count > 0) otel_api.logs.Severity.warn else otel_api.logs.Severity.info;
    const error_message = if (final_error_count > 0) "Application completed with errors" else "Application completed successfully with no errors";

    main_logger.emitLog(
        &.{},
        error_log_level,
        error_message,
        &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "total_errors", .value = .{ .int = @intCast(final_error_count) } },
            .{ .key = "error_rate", .value = .{ .float = if (final_error_count > 0) @as(f64, @floatFromInt(final_error_count)) / @as(f64, @floatFromInt(config.duration_seconds)) else 0.0 } },
            .{ .key = "has_errors", .value = .{ .bool = final_error_count > 0 } },
            .{ .key = "execution_duration_seconds", .value = .{ .int = @intCast(config.duration_seconds) } },
        },
        null, // event_name
    );

    main_logger.emitLog(
        &.{},
        .info,
        "Application shutting down",
        &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "final_uptime_ns", .value = .{ .int = @intCast(shared_state.getUptimeNs()) } },
            .{ .key = "total_errors", .value = .{ .int = @intCast(final_error_count) } },
        },
        null, // event_name
    );

    print("\n🏁 Both threads completed successfully!\n", .{});
    print("📊 Enhanced telemetry features demonstrated:\n", .{});
    print("   📝 Logs: Structured logging with batch processing\n", .{});
    print("   📈 Metrics: 3 views created from histogram + observable uptime gauge\n", .{});
    print("   🔍 Traces: Spans with events, links, and context propagation\n", .{});
    print("   🎯 Sampling: TraceIdRatioBasedSampler with {d:.1} head-based sampling\n", .{config.sampling_ratio});
    print("   🔗 Links: Each iteration linked to previous (follows_from relationship)\n", .{});
    print("   📅 Events: Number generation, HTTP requests, responses, errors\n", .{});
    print("   ❌ Errors: {} overflow errors occurred during execution\n", .{final_error_count});
    print("✅ Comprehensive OpenTelemetry demo completed!\n", .{});
}

fn processHttpRequest(ctx: []otel_api.ContextKeyValue, http_context: *HttpContext, logger: *otel_api.logs.Logger, allocator: std.mem.Allocator, io: std.Io) void {
    // Create HTTP client
    var http_client = std.http.Client{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    // Build URL for the request
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:8080/multiply/{d}/{d}", .{ http_context.num1, http_context.num2 }) catch return;
    defer allocator.free(url);

    // Parse URI
    const uri = std.Uri.parse(url) catch return;

    // Create request with traceparent and tracestate headers
    var headers_buf: [2]std.http.Header = undefined;
    var headers_len: usize = 0;
    if (http_context.traceparent) |tp| {
        headers_buf[headers_len] = .{ .name = "traceparent", .value = tp };
        headers_len += 1;
    }
    if (http_context.tracestate) |ts| {
        headers_buf[headers_len] = .{ .name = "tracestate", .value = ts };
        headers_len += 1;
    }
    var resp_writer = std.Io.Writer.Allocating.init(allocator);
    defer resp_writer.deinit();
    const result = http_client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .extra_headers = headers_buf[0..headers_len],
        .response_writer = &resp_writer.writer,
    }) catch return;

    http_context.status_code = @intCast(@intFromEnum(result.status));

    const product = resp_writer.toOwnedSlice() catch return;
    defer allocator.free(product);
    switch (result.status) {
        .ok => {
            // Parse successful response body as result
            http_context.result = std.fmt.parseInt(u64, product, 10) catch 0;

            logger.emitLog(
                ctx,
                .debug,
                "HTTP request successful",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "num1", .value = .{ .int = @intCast(http_context.num1) } },
                    .{ .key = "num2", .value = .{ .int = @intCast(http_context.num2) } },
                    .{ .key = "result", .value = .{ .int = @intCast(http_context.result) } },
                    .{ .key = "status_code", .value = .{ .int = 200 } },
                    .{ .key = "component", .value = .{ .string = "http_client" } },
                },
                null, // event_name
            );
        },
        .bad_request => {
            // Handle 400 Bad Request
            http_context.result = 0;

            logger.emitLog(
                ctx,
                .@"error",
                "HTTP request failed: Bad Request",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "num1", .value = .{ .int = @intCast(http_context.num1) } },
                    .{ .key = "num2", .value = .{ .int = @intCast(http_context.num2) } },
                    .{ .key = "status_code", .value = .{ .int = 400 } },
                    .{ .key = "error_message", .value = .{ .string = product } },
                    .{ .key = "component", .value = .{ .string = "http_client" } },
                },
                null, // event_name
            );
        },
        .internal_server_error => {
            // Handle 500 Internal Server Error (overflow case)
            http_context.result = @as(u64, http_context.num1) * @as(u64, http_context.num2); // Calculate locally for reporting

            logger.emitLog(
                ctx,
                .@"error",
                "HTTP request failed: Server Error (overflow)",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "num1", .value = .{ .int = @intCast(http_context.num1) } },
                    .{ .key = "num2", .value = .{ .int = @intCast(http_context.num2) } },
                    .{ .key = "calculated_result", .value = .{ .int = @intCast(http_context.result) } },
                    .{ .key = "status_code", .value = .{ .int = 500 } },
                    .{ .key = "error_message", .value = .{ .string = product } },
                    .{ .key = "component", .value = .{ .string = "http_client" } },
                },
                null, // event_name
            );
        },
        else => {
            // Handle other status codes
            http_context.result = 0;

            logger.emitLog(
                ctx,
                .@"error",
                "HTTP request failed: Unexpected status",
                &[_]otel_api.common.AttributeKeyValue{
                    .{ .key = "num1", .value = .{ .int = @intCast(http_context.num1) } },
                    .{ .key = "num2", .value = .{ .int = @intCast(http_context.num2) } },
                    .{ .key = "status_code", .value = .{ .int = @intCast(http_context.status_code) } },
                    .{ .key = "component", .value = .{ .string = "http_client" } },
                },
                null, // event_name
            );
        },
    }
}

/// Custom trace provider setup with configurable sampling
fn setupCustomTraceProvider(allocator: std.mem.Allocator, io: std.Io, sampling_ratio: f64, links: anytype) !*otel_sdk.trace.TracerProvider {
    const createDefaultIdGenerator = otel_sdk.trace.createDefaultIdGenerator;
    const samplers = otel_sdk.trace.samplers;

    // 1. Create heap-allocated concrete provider
    const provider_ptr = try allocator.create(otel_sdk.trace.TracerProvider);
    errdefer allocator.destroy(provider_ptr);

    // 2. Create resource with service name (ownership transfers to provider below)
    const final_resource = try createServiceResource(allocator, io);

    // 3. Create custom sampler based on sampling ratio
    const sampler = if (sampling_ratio >= 1.0)
        samplers.always_on
    else if (sampling_ratio <= 0.0)
        samplers.always_off
    else
        samplers.traceIdRatioBased(sampling_ratio);

    // 4. Initialize provider with custom sampler and final resource
    provider_ptr.* = otel_sdk.trace.TracerProvider.init(
        allocator,
        io,
        final_resource,
        createDefaultIdGenerator(),
        sampler,
    );
    errdefer provider_ptr.deinit();

    // 5. Configure pipeline using the links tuple
    var builder = provider_ptr.pipelineBuilder();
    inline for (links) |link| {
        builder = builder.with(link);
    }
    try builder.done();

    // 6. Register with global registry
    try otel_api.provider_registry.setGlobalTracerProvider(provider_ptr.tracerProvider());

    // 7. Return concrete provider pointer for caller management
    return provider_ptr;
}

/// Custom log provider setup with service name in resource
fn setupCustomLogProvider(allocator: std.mem.Allocator, io: std.Io, resource: otel_sdk.resource.Resource, links: anytype) !*otel_sdk.logs.LoggerProvider {

    // 1. Create heap-allocated concrete provider
    const provider_ptr = try allocator.create(otel_sdk.logs.LoggerProvider);
    errdefer allocator.destroy(provider_ptr);

    // 2. Initialize provider with the provided resource (resource is already owned by caller)
    provider_ptr.* = otel_sdk.logs.LoggerProvider.init(allocator, io, resource);
    errdefer provider_ptr.deinit();
    provider_ptr.default_min_severity = .warn;

    // 3. Configure pipeline using the links tuple
    var builder = provider_ptr.pipelineBuilder();
    inline for (links) |link| {
        builder = builder.with(link);
    }
    try builder.done();

    // 4. Register with global registry
    try otel_api.provider_registry.setGlobalLoggerProvider(provider_ptr.loggerProvider());

    // 5. Return concrete provider pointer for caller management
    return provider_ptr;
}

/// Custom metric provider setup with service name in resource
fn setupCustomMetricProvider(allocator: std.mem.Allocator, io: std.Io, links: anytype, views: anytype) !*otel_sdk.metrics.MeterProvider {

    // 1. Create heap-allocated concrete provider
    const provider_ptr = try allocator.create(otel_sdk.metrics.MeterProvider);
    errdefer allocator.destroy(provider_ptr);

    // 2. Create resource with service name
    const final_resource = try createServiceResource(allocator, io);

    // 3. Initialize provider with service resource
    provider_ptr.* = otel_sdk.metrics.MeterProvider.init(allocator, io, final_resource);
    errdefer provider_ptr.deinit();

    // 4. Register views before pipeline setup
    inline for (views) |view| {
        try provider_ptr.addView(view);
    }

    // 5. Configure pipeline using the links tuple
    var builder = provider_ptr.pipelineBuilder();
    inline for (links) |link| {
        builder = builder.with(link);
    }
    try builder.done();

    // 6. Register with global registry
    try otel_api.provider_registry.setGlobalMeterProvider(provider_ptr.meterProvider());

    // 7. Return concrete provider pointer for caller management
    return provider_ptr;
}

/// Helper function to create resource with service name
fn createServiceResource(allocator: std.mem.Allocator, io: std.Io) !@import("otel-sdk").resource.Resource {
    const detectResource = @import("otel-sdk").resource.detectResource;
    const Resource = @import("otel-sdk").resource.Resource;

    // 1. Detect base resource
    const detected_resource = try detectResource(allocator, io);
    errdefer detected_resource.deinitOwned(allocator);

    // 2. Create service resource with service name
    var service_attrs = otel_api.common.AttributeBuilder.init(allocator);
    service_attrs = service_attrs.add(.{ .key = otel_semconv.SERVICE_NAME, .value = .{ .string = "multithreaded_http_telemetry" } });
    const service_resource = try Resource.initOwnedFromBuilder(
        allocator,
        null,
        &service_attrs,
    );
    errdefer service_resource.deinitOwned(allocator);

    // 3. Merge detected resource with service resource
    const final_resource = try Resource.initOwnedMerge(allocator, detected_resource, service_resource);

    // 4. Clean up intermediate resources
    detected_resource.deinitOwned(allocator);
    service_resource.deinitOwned(allocator);

    return final_resource;
}
