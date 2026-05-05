//! Simple Trace OTLP Example
//!
//! This example demonstrates basic usage of the OpenTelemetry Trace SDK
//! implementation in Zig, including span creation, attributes, and OTLP export.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Set up trace provider using the new setupGlobalProvider pattern
    const concrete_provider = try otel_sdk.trace.setupGlobalProvider(
        init,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(.{ .io = io }))},
        null,
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get the global tracer provider interface
    var tp = otel_api.getGlobalTracerProvider();

    // Get a tracer
    const scope = otel_api.InstrumentationScope{ .name = "example-component", .version = "1.0.0" };
    var tracer = try tp.getTracerWithScope(scope);

    // Create a root context
    const ctx = &[_]otel_api.ContextKeyValue{};

    // Start a parent span
    std.debug.print("Starting parent span...\n", .{});
    const parent_result = tracer.startSpan("parent-operation", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "http.method",
                .value = otel_api.common.AttributeValue{ .string = "GET" },
            },
            .{
                .key = "http.url",
                .value = otel_api.common.AttributeValue{ .string = "/api/example" },
            },
        },
    }, ctx);
    var parent_span = parent_result;
    defer parent_span.deinit();

    // Add an event to the parent span
    try parent_span.addEvent(otel_api.trace.Span.Event{
        .name = "request.started",
        // timestamp omitted — SDK stamps current time
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "client.ip",
                .value = otel_api.common.AttributeValue{ .string = "192.168.1.100" },
            },
        },
    });

    // Start a child span
    std.debug.print("Starting child span...\n", .{});
    const child_ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, ctx, parent_span.getSpanContext());
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, child_ctx);
    const child_result = tracer.startSpan("database-query", .{
        .kind = .client,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "db.system",
                .value = otel_api.common.AttributeValue{ .string = "postgresql" },
            },
            .{
                .key = "db.statement",
                .value = otel_api.common.AttributeValue{ .string = "SELECT * FROM users WHERE id = ?" },
            },
        },
    }, child_ctx);
    var child_span = child_result;
    defer child_span.deinit();

    // Simulate some work
    try std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

    // Add result attribute to child span
    child_span.setAttribute(.{ .key = "db.rows_affected", .value = otel_api.common.AttributeValue{ .int = 1 } });

    // End child span
    std.debug.print("Ending child span...\n", .{});
    child_span.end(null);

    // Add response attributes to parent span
    parent_span.setAttribute(.{ .key = "http.status_code", .value = otel_api.common.AttributeValue{ .int = 200 } });
    parent_span.setAttribute(.{ .key = "http.response.size", .value = otel_api.common.AttributeValue{ .int = 1024 } });

    // Set status
    parent_span.setStatus(.{ .code = .ok, .description = "Request completed successfully" });

    // End parent span
    std.debug.print("Ending parent span...\n", .{});
    parent_span.end(null);

    std.debug.print("\nSpans exported via OTLP to http://localhost:4318/v1/traces\n", .{});
}
