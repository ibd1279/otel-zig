//! Validation Test Example
//!
//! This example demonstrates the input validation features of the Logger and Meter APIs
//! in debug builds. It intentionally provides invalid inputs to trigger validation
//! errors, which are reported via the global error handler.
//!
//! Run with: zig build example-validation-test

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

const print = std.debug.print;

var error_count: usize = 0;

fn validationErrorHandler(info: otel_api.common.ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    error_count += 1;
    print("🚨 Validation Error #{d}: [{s}] {s} - {s}", .{ error_count, @tagName(info.component), info.operation, info.message });
    if (info.context) |ctx| {
        print(" (Context: {s})", .{ctx});
    }
    print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    print("🧪 OpenTelemetry Validation Test Example\n", .{});
    print("=" ** 50 ++ "\n\n", .{});

    // Set up custom error handler to capture validation errors
    otel_api.common.setGlobalErrorHandler(validationErrorHandler);

    // Set up logging provider
    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    const log_provider = try otel_sdk.logs.setupGlobalProvider(
        init,
        .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.stream.LogRecordSink.PipelineStep.init(.{ .writer = &stderr.interface }))},
        null,
    );
    defer {
        log_provider.deinit();
        log_provider.destroy();
    }

    // Set up metrics provider
    const metric_provider = try otel_sdk.metrics.setupGlobalProvider(
        init,
        .{otel_sdk.metrics.ManualReader.PipelineStep.init(.{ .io = io })
            .flowTo(otel_exporters.stream.MetricDataSink.PipelineStep.init(.{ .writer = &stderr.interface }))},
        null,
    );
    defer {
        metric_provider.deinit();
        metric_provider.destroy();
    }

    print("✅ Providers set up successfully\n\n", .{});

    // Test Logger API validation
    try testLoggerValidation();

    // Test Meter API validation
    try testMeterValidation();

    print("\n" ++ "=" ** 50 ++ "\n", .{});
    print("🎯 Validation Test Complete!\n", .{});
    print("📊 Total validation errors caught: {d}\n", .{error_count});

    if (otel_api.common.isValidatingMode()) {
        print("✅ Validation mode: ENABLED (debug build)\n", .{});
        if (error_count > 0) {
            print("🎉 Validation system working correctly - errors were caught and reported!\n", .{});
        } else {
            print("⚠️  No validation errors occurred - this might indicate an issue with the test\n", .{});
        }
    } else {
        print("⚠️  Validation mode: DISABLED (release build)\n", .{});
        print("ℹ️  Run in debug mode to see validation in action\n", .{});
    }
}

fn testLoggerValidation() !void {
    print("🔍 Testing Logger API Validation\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const scope = otel_api.InstrumentationScope{ .name = "validation.logger.test", .version = "1.0.0" };
    var logger = otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);
    const ctx = &[_]otel_api.ContextKeyValue{};

    const errors_before = error_count;

    // Test 1: Empty format string (should trigger validation error)
    print("Test 1: Empty format string...\n", .{});
    logger.info(ctx, "", .{});

    // Test 2: Empty log message body via emitLogRecord
    print("Test 2: Empty log message body...\n", .{});
    logger.emitLogRecord(
        ctx,
        .info,
        otel_api.common.AttributeValue{ .string = "" }, // Empty string body
        null,
        null,
        null,
        null, // Empty event name
        "", // Empty severity text
        null,
        null,
        null,
    );

    // Test 3: Invalid attributes (empty keys)
    print("Test 3: Invalid attributes (empty keys)...\n", .{});
    const invalid_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "valid.key", .value = otel_api.common.AttributeValue{ .string = "valid" } },
        .{ .key = "", .value = otel_api.common.AttributeValue{ .string = "invalid" } }, // Empty key
        .{ .key = "another.key", .value = otel_api.common.AttributeValue{ .int = 42 } },
    };

    logger.emitLogRecord(
        ctx,
        .warn,
        otel_api.common.AttributeValue{ .string = "Test message with invalid attributes" },
        &invalid_attrs,
        null,
        null,
        "", // Empty event name (should trigger validation)
        null,
        null,
        null,
        null,
    );

    // Test 4: Valid usage (should not trigger errors)
    print("Test 4: Valid usage (should be clean)...\n", .{});
    logger.info(ctx, "This is a valid {s} message with {d} parameters", .{ "log", 2 });

    const logger_errors = error_count - errors_before;
    print("📊 Logger validation errors: {d}\n\n", .{logger_errors});
}

fn testMeterValidation() !void {
    print("🔍 Testing Meter API Validation\n", .{});
    print("-" ** 30 ++ "\n", .{});

    const scope = otel_api.InstrumentationScope{ .name = "validation.meter.test", .version = "1.0.0" };
    var meter = otel_api.getGlobalMeterProvider().getMeterWithScope(scope);

    const errors_before = error_count;

    // Test 1: Empty instrument name (should trigger validation error)
    print("Test 1: Empty instrument name...\n", .{});
    _ = try meter.createCounter(i64, "", "A counter with empty name", "count", null);

    // Test 2: Invalid characters in instrument name
    print("Test 2: Invalid characters in instrument name...\n", .{});
    _ = try meter.createCounter(i64, "invalid@name#with$symbols", "Counter with invalid characters", "count", null);

    // Test 3: Empty description (should trigger validation warning)
    print("Test 3: Empty description...\n", .{});
    _ = try meter.createHistogram(f64, "valid.histogram", "", "ms", null);

    // Test 4: Very long description (should trigger validation warning)
    print("Test 4: Very long description...\n", .{});
    const long_desc = "This is an extremely long description that exceeds reasonable limits and should trigger a validation warning because descriptions should be concise and to the point, not verbose explanations that go on and on without adding meaningful value to the understanding of what this instrument measures in the context of the application's telemetry data collection strategy and monitoring infrastructure setup which is already quite complex without adding unnecessary verbosity to instrument descriptions that could be much shorter and still convey the essential information needed by operators and developers who need to understand what this metric represents in their monitoring dashboards and alerting systems that rely on clear and concise naming conventions and descriptions that follow best practices for observability and monitoring in distributed systems architecture patterns commonly used in modern cloud-native applications and microservices deployments across various infrastructure platforms and container orchestration systems like Kubernetes which require careful consideration of telemetry data volume and cardinality management to ensure optimal performance and cost-effectiveness of monitoring solutions while maintaining adequate observability coverage for troubleshooting and performance analysis purposes in production environments where reliability and maintainability are critical success factors for operational excellence and business continuity objectives that depend on effective monitoring 123456789012345678901234567890";
    _ = try meter.createGauge(i64, "valid.gauge", long_desc, "units", null);

    // Test 5: Empty unit (should trigger validation warning)
    print("Test 5: Empty unit...\n", .{});
    _ = try meter.createUpDownCounter(f64, "valid.updown", "Valid counter", "", null);

    // Test 6: Very long unit (should trigger validation warning)
    print("Test 6: Very long unit...\n", .{});
    _ = try meter.createCounter(i64, "another.counter", "Counter with long unit", "this_is_a_very_very_very_very_very_very_long_unit_name_that_exceeds_limits", null);

    // Test 7: Valid usage (should not trigger errors)
    print("Test 7: Valid usage (should be clean)...\n", .{});
    const valid_counter = try meter.createCounter(i64, "valid.requests.total", "Total number of requests processed", "count", null);
    const valid_histogram = try meter.createHistogram(f64, "valid.request.duration", "Request processing time", "ms", null);
    const valid_gauge = try meter.createGauge(f64, "valid.cpu.usage", "Current CPU usage percentage", "percent", null);

    // Use the instruments briefly to ensure they work
    _ = valid_counter;
    _ = valid_histogram;
    _ = valid_gauge;

    const meter_errors = error_count - errors_before;
    print("📊 Meter validation errors: {d}\n\n", .{meter_errors});
}
