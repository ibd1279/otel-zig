//! Comprehensive Trace SDK Example
//!
//! This example demonstrates advanced usage of the OpenTelemetry Trace SDK
//! implementation in Zig, including multiple span kinds, error handling,
//! concurrent operations, and realistic microservice scenarios.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

const print = std.debug.print;

// Simulate different service components
const ServiceComponent = enum {
    api_gateway,
    user_service,
    order_service,
    database,
    message_queue,
    payment_service,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    print("🚀 Starting Comprehensive Trace SDK Example\n", .{});
    print("=" ** 50 ++ "\n", .{});

    // Set up trace provider using the new setupGlobalProvider pattern
    // Note: setupGlobalProvider uses automatic resource detection
    // The custom resource above demonstrates resource building but won't be used
    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    const concrete_provider = try otel_sdk.trace.setupGlobalProvider(
        init,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.stream.SpanDataSink.PipelineStep.init(.{
            .writer = &stderr.interface,
            .flush_after_each = true,
            .include_attributes = true,
        }))},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    var trace_setup = TraceSetup{
        .allocator = allocator,
        .tracer_provider = @constCast(otel_api.getGlobalTracerProvider()),
    };

    // Run different test scenarios
    try runHttpRequestScenario(io, &trace_setup);
    try runErrorHandlingScenario(&trace_setup);
    try runMessageQueueScenario(io, &trace_setup);
    try runConcurrentOperationsScenario(io, allocator, &trace_setup);
    try runPerformanceTestScenario(&trace_setup);

    print("\n✅ All trace scenarios completed successfully!\n", .{});
    print("Check the console output above for OTLP JSON traces.\n", .{});
}

const TraceSetup = struct {
    allocator: std.mem.Allocator,
    tracer_provider: *otel_api.trace.TracerProvider,
};

fn getTracer(setup: *TraceSetup, component: ServiceComponent) !otel_api.trace.Tracer {
    const component_name = switch (component) {
        .api_gateway => "api-gateway",
        .user_service => "user-service",
        .order_service => "order-service",
        .database => "database-client",
        .message_queue => "message-queue-client",
        .payment_service => "payment-service",
    };

    const scope = otel_api.InstrumentationScope{ .name = component_name, .version = "1.0.0" };
    return try setup.tracer_provider.getTracerWithScope(scope);
}

fn runHttpRequestScenario(io: std.Io, setup: *TraceSetup) !void {
    print("\n📡 HTTP Request Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = &[_]otel_api.ContextKeyValue{};

    // API Gateway receives request
    var api_tracer = try getTracer(setup, .api_gateway);
    const gateway_result = try api_tracer.startSpan("POST /api/orders", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "http.method", .value = .{ .string = "POST" } },
            .{ .key = "http.url", .value = .{ .string = "/api/orders" } },
            .{ .key = "http.scheme", .value = .{ .string = "https" } },
            .{ .key = "http.host", .value = .{ .string = "api.example.com" } },
            .{ .key = "user.id", .value = .{ .string = "user123" } },
            .{ .key = "http.user_agent", .value = .{ .string = "curl/7.68.0" } },
        },
    }, ctx);
    var gateway_span = gateway_result;
    defer gateway_span.deinit();

    try gateway_span.addEvent(otel_api.trace.Span.Event{
        .name = "request.validation.started",
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "validation.schema_version", .value = .{ .string = "v1.2" } },
        },
    });

    // User service validates user
    var user_tracer = try getTracer(setup, .user_service);
    const user_ctx = try otel_api.trace.trace_context.withActiveSpanContext(setup.allocator, ctx, gateway_span.getSpanContext());
    defer otel_api.ContextKeyValue.deinitOwnedSlice(setup.allocator, user_ctx);
    const user_result = try user_tracer.startSpan("validate_user", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "user.id", .value = .{ .string = "user123" } },
            .{ .key = "operation.type", .value = .{ .string = "validation" } },
        },
    }, user_ctx);
    var user_span = user_result;
    defer user_span.deinit();

    // Database query in user service
    var db_tracer = try getTracer(setup, .database);
    const db_ctx = try otel_api.trace.trace_context.withActiveSpanContext(setup.allocator, ctx, user_span.getSpanContext());
    defer otel_api.ContextKeyValue.deinitOwnedSlice(setup.allocator, db_ctx);
    const db_result = try db_tracer.startSpan("SELECT users", .{
        .kind = .client,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "db.system", .value = .{ .string = "postgresql" } },
            .{ .key = "db.name", .value = .{ .string = "users_db" } },
            .{ .key = "db.statement", .value = .{ .string = "SELECT id, email, status FROM users WHERE id = $1" } },
            .{ .key = "db.operation", .value = .{ .string = "SELECT" } },
            .{ .key = "server.address", .value = .{ .string = "db.internal.com" } },
            .{ .key = "server.port", .value = .{ .int = 5432 } },
        },
    }, db_ctx);
    var db_span = db_result;
    defer db_span.deinit();

    // Simulate database work
    try std.Io.sleep(io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake);
    db_span.setAttribute(.{ .key = "db.rows_affected", .value = .{ .int = 1 } });
    db_span.end(null);

    user_span.setAttribute(.{ .key = "user.status", .value = .{ .string = "active" } });
    user_span.end(null);

    // Order service processes the order
    var order_tracer = try getTracer(setup, .order_service);
    const order_ctx = try otel_api.trace.trace_context.withActiveSpanContext(setup.allocator, ctx, gateway_span.getSpanContext());
    defer otel_api.ContextKeyValue.deinitOwnedSlice(setup.allocator, order_ctx);
    const order_result = try order_tracer.startSpan("create_order", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "order.type", .value = .{ .string = "standard" } },
            .{ .key = "order.item_count", .value = .{ .int = 3 } },
            .{ .key = "order.total_amount", .value = .{ .float = 99.99 } },
        },
    }, order_ctx);
    var order_span = order_result;
    defer order_span.deinit();

    try order_span.addEvent(otel_api.trace.Span.Event{
        .name = "inventory.check",
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "inventory.available", .value = .{ .bool = true } },
        },
    });

    order_span.setAttribute(.{ .key = "order.id", .value = .{ .string = "order_789" } });
    order_span.end(null);

    // Complete gateway span
    gateway_span.setAttribute(.{ .key = "http.status_code", .value = .{ .int = 201 } });
    gateway_span.setAttribute(.{ .key = "http.response.size", .value = .{ .int = 156 } });
    gateway_span.setStatus(.{ .code = .ok, .description = "Order created successfully" });
    gateway_span.end(null);

    print("✅ HTTP request scenario completed\n", .{});
}

fn runErrorHandlingScenario(setup: *TraceSetup) !void {
    print("\n❌ Error Handling Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = &[_]otel_api.ContextKeyValue{};

    // Start a payment processing operation that will fail
    var payment_tracer = try getTracer(setup, .payment_service);
    const payment_result = try payment_tracer.startSpan("process_payment", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "payment.method", .value = .{ .string = "credit_card" } },
            .{ .key = "payment.amount", .value = .{ .float = 299.99 } },
            .{ .key = "payment.currency", .value = .{ .string = "USD" } },
            .{ .key = "customer.id", .value = .{ .string = "cust456" } },
        },
    }, ctx);
    var payment_span = payment_result;
    defer payment_span.deinit();

    // Card validation sub-operation
    const validation_ctx = try otel_api.trace.trace_context.withActiveSpanContext(setup.allocator, ctx, payment_span.getSpanContext());
    defer otel_api.ContextKeyValue.deinitOwnedSlice(setup.allocator, validation_ctx);
    const validation_result = try payment_tracer.startSpan("validate_card", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "card.type", .value = .{ .string = "visa" } },
            .{ .key = "card.last_four", .value = .{ .string = "1234" } },
        },
    }, validation_ctx);
    var validation_span = validation_result;
    defer validation_span.deinit();

    // Simulate validation failure
    try validation_span.addEvent(.{
        .name = "validation.failed",
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "error.type", .value = .{ .string = "invalid_card" } },
            .{ .key = "error.message", .value = .{ .string = "Card has expired" } },
        },
    });

    validation_span.setStatus(.{ .code = .@"error", .description = "Card validation failed: expired" });
    validation_span.setAttribute(.{ .key = "validation.result", .value = .{ .string = "failed" } });
    validation_span.end(null);

    // Parent span also fails
    try payment_span.addEvent(.{
        .name = "payment.declined",
        .attributes = &.{
            .{ .key = "decline.reason", .value = .{ .string = "expired_card" } },
            .{ .key = "retry.allowed", .value = .{ .bool = true } },
        },
    });

    payment_span.setAttribute(.{ .key = "payment.status", .value = .{ .string = "declined" } });
    payment_span.setStatus(.{ .code = .@"error", .description = "Payment declined due to expired card" });
    payment_span.end(null);

    print("✅ Error handling scenario completed\n", .{});
}

fn runMessageQueueScenario(io: std.Io, setup: *TraceSetup) !void {
    print("\n📨 Message Queue Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = &[_]otel_api.ContextKeyValue{};

    var mq_tracer = try getTracer(setup, .message_queue);

    // Producer: Send message to queue
    const producer_result = try mq_tracer.startSpan("order.created", .{
        .kind = .producer,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "messaging.system", .value = .{ .string = "rabbitmq" } },
            .{ .key = "messaging.destination.name", .value = .{ .string = "order.events" } },
            .{ .key = "messaging.destination.kind", .value = .{ .string = "queue" } },
            .{ .key = "messaging.operation", .value = .{ .string = "publish" } },
            .{ .key = "messaging.message.id", .value = .{ .string = "msg_12345" } },
            .{ .key = "messaging.message.payload_size_bytes", .value = .{ .int = 512 } },
        },
    }, ctx);
    var producer_span = producer_result;
    defer producer_span.deinit();

    try producer_span.addEvent(.{
        .name = "message.queued",
        .attributes = &.{
            .{ .key = "serialization.format", .value = .{ .string = "json" } },
        },
    });

    producer_span.setAttribute(.{ .key = "messaging.message.envelope.size", .value = .{ .int = 587 } });
    producer_span.end(null);

    // Simulate message transmission delay
    try std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);

    // Consumer: Process message from queue
    const consumer_result = try mq_tracer.startSpan("order.created", .{
        .kind = .consumer,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "messaging.system", .value = .{ .string = "rabbitmq" } },
            .{ .key = "messaging.destination.name", .value = .{ .string = "order.events" } },
            .{ .key = "messaging.destination.kind", .value = .{ .string = "queue" } },
            .{ .key = "messaging.operation", .value = .{ .string = "receive" } },
            .{ .key = "messaging.message.id", .value = .{ .string = "msg_12345" } },
        },
    }, ctx);
    var consumer_span = consumer_result;
    defer consumer_span.deinit();

    // Message processing
    const processing_ctx = try otel_api.trace.trace_context.withActiveSpanContext(setup.allocator, ctx, consumer_span.getSpanContext());
    defer otel_api.ContextKeyValue.deinitOwnedSlice(setup.allocator, processing_ctx);
    const processing_result = try mq_tracer.startSpan("process_order_event", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "event.type", .value = .{ .string = "order.created" } },
            .{ .key = "processing.handler", .value = .{ .string = "OrderEventHandler" } },
        },
    }, processing_ctx);
    var processing_span = processing_result;
    defer processing_span.deinit();

    try processing_span.addEvent(.{
        .name = "order.processing.started",
        .attributes = &.{
            .{ .key = "inventory.change", .value = .{ .int = -3 } },
        },
    });

    processing_span.end(null);
    consumer_span.setAttribute(.{ .key = "processing.result", .value = .{ .string = "success" } });
    consumer_span.end(null);

    print("✅ Message queue scenario completed\n", .{});
}

fn runConcurrentOperationsScenario(io: std.Io, allocator: std.mem.Allocator, setup: *TraceSetup) !void {
    print("\n🔄 Concurrent Operations Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = &[_]otel_api.ContextKeyValue{};

    // Simulate concurrent database operations
    var api_tracer = try getTracer(setup, .api_gateway);
    const batch_result = try api_tracer.startSpan("batch_user_lookup", .{
        .kind = .server,
        .attributes = &.{
            .{ .key = "batch.size", .value = .{ .int = 3 } },
            .{ .key = "batch.type", .value = .{ .string = "user_lookup" } },
        },
    }, ctx);
    var batch_span = batch_result;
    defer batch_span.deinit();

    // Create multiple concurrent database operations
    const user_ids = [_][]const u8{ "user001", "user002", "user003" };
    var db_tracer = try getTracer(setup, .database);

    for (user_ids, 0..) |user_id, i| {
        const query_name = try std.fmt.allocPrint(allocator, "SELECT user {s}", .{user_id});
        defer allocator.free(query_name);

        const query_ctx = try otel_api.trace.trace_context.withActiveSpanContext(setup.allocator, ctx, batch_span.getSpanContext());
        defer otel_api.ContextKeyValue.deinitOwnedSlice(setup.allocator, query_ctx);
        const db_result = try db_tracer.startSpan(query_name, .{
            .kind = .client,
            .attributes = &.{
                .{ .key = "db.system", .value = .{ .string = "postgresql" } },
                .{ .key = "db.statement", .value = .{ .string = "SELECT * FROM users WHERE id = $1" } },
                .{ .key = "user.id", .value = .{ .string = user_id } },
                .{ .key = "query.index", .value = .{ .int = @intCast(i) } },
            },
        }, query_ctx);
        var db_span = db_result;
        defer db_span.deinit();

        // Simulate varying query times
        const sleep_ns: u64 = (i + 1) * 2 * std.time.ns_per_ms;
        try std.Io.sleep(io, .{ .nanoseconds = sleep_ns }, .awake);

        db_span.setAttribute(.{ .key = "db.rows_affected", .value = .{ .int = 1 } });
        db_span.setAttribute(.{ .key = "query.duration_ms", .value = .{ .int = @intCast((i + 1) * 2) } });
        db_span.end(null);
    }

    batch_span.setAttribute(.{ .key = "batch.processed", .value = .{ .int = user_ids.len } });
    batch_span.setAttribute(.{ .key = "batch.status", .value = .{ .string = "completed" } });
    batch_span.end(null);

    print("✅ Concurrent operations scenario completed\n", .{});
}

fn runPerformanceTestScenario(setup: *TraceSetup) !void {
    print("\n⚡ Performance Test Scenario\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const ctx = &[_]otel_api.ContextKeyValue{};

    var api_tracer = try getTracer(setup, .api_gateway);
    const perf_result = try api_tracer.startSpan("performance_test", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "test.type", .value = .{ .string = "span_creation_overhead" } },
            .{ .key = "test.iterations", .value = .{ .int = 100 } },
        },
    }, ctx);
    var perf_span = perf_result;
    defer perf_span.deinit();

    const start_instant = try std.time.Instant.now();

    // Create many short-lived spans to test overhead
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        const span_name = "fast_operation";
        const fast_ctx = try otel_api.trace.trace_context.withActiveSpanContext(setup.allocator, ctx, perf_span.getSpanContext());
        defer otel_api.ContextKeyValue.deinitOwnedSlice(setup.allocator, fast_ctx);
        const fast_result = try api_tracer.startSpan(span_name, .{
            .kind = .internal,
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "iteration", .value = .{ .int = i } },
                .{ .key = "operation.type", .value = .{ .string = "fast" } },
            },
        }, fast_ctx);
        var fast_span = fast_result;
        defer fast_span.deinit();

        // Minimal work
        fast_span.setAttribute(.{ .key = "work.completed", .value = .{ .bool = true } });
        fast_span.end(null);
    }

    const end_instant = try std.time.Instant.now();
    const duration_ns: i64 = @intCast(end_instant.since(start_instant));
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    perf_span.setAttribute(.{ .key = "test.duration_ms", .value = .{ .float = duration_ms } });
    perf_span.setAttribute(.{ .key = "test.avg_span_creation_ns", .value = .{ .int = @intCast(@divTrunc(duration_ns, 10)) } });
    try perf_span.addEvent(.{
        .name = "performance.measurement.completed",
        .attributes = &.{
            .{ .key = "measurement.accuracy", .value = .{ .string = "nanosecond" } },
        },
    });

    perf_span.end(null);

    print("✅ Performance test scenario completed ({}ms for 10 spans)\n", .{duration_ms});
}
