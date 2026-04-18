//! Tests for Observable Instruments SDK Implementation
//!
//! This module tests the SDK-level functionality of observable instruments,
//! including callback execution, metric collection, error handling policies,
//! and callback metrics.

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const ObservableResult = otel_api.metrics.ObservableResult;
const TypeErasedCallback = otel_api.metrics.TypeErasedCallback;
const createTypeErasedCallback = otel_api.metrics.createTypeErasedCallback;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;

const AsyncInstrumentConfig = otel_sdk.metrics.AsyncInstrumentConfig;
const CallbackErrorPolicy = otel_sdk.metrics.CallbackErrorPolicy;
const SdkObservableCounter = otel_sdk.metrics.SdkObservableCounter;
const SdkObservableGauge = otel_sdk.metrics.SdkObservableGauge;
const SdkObservableUpDownCounter = otel_sdk.metrics.SdkObservableUpDownCounter;
const CallbackMetrics = otel_sdk.metrics.CallbackMetrics;

// Test state for callbacks
const TestState = struct {
    value: i64 = 42,
    call_count: u32 = 0,
    should_error: bool = false,
};

// Test callbacks
fn testCallback(result: *ObservableResult(i64), state: *TestState) void {
    state.call_count += 1;
    if (state.should_error) {
        // Simulate an error by returning without observing
        return;
    }

    const attrs = [_]AttributeKeyValue{
        .{ .key = "test", .value = .{ .string = "callback" } },
        .{ .key = "call_count", .value = .{ .int = @intCast(state.call_count) } },
    };
    result.observe(state.value, &attrs, null) catch {};
}

fn testCallbackMultiple(result: *ObservableResult(i64), state: *TestState) void {
    state.call_count += 1;

    // Produce multiple measurements
    const attrs1 = [_]AttributeKeyValue{
        .{ .key = "instance", .value = .{ .string = "A" } },
    };
    const attrs2 = [_]AttributeKeyValue{
        .{ .key = "instance", .value = .{ .string = "B" } },
    };

    result.observe(state.value, &attrs1, null) catch {};
    result.observe(state.value + 10, &attrs2, null) catch {};
}

fn testCallbackNoState(result: *ObservableResult(i64)) void {
    result.observeValue(999) catch {};
}

fn testCallbackF64(result: *ObservableResult(f64), state: *TestState) void {
    state.call_count += 1;
    result.observeValue(@as(f64, @floatFromInt(state.value)) + 0.5) catch {};
}

test "SdkObservableCounter basic functionality" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.counter",
        "Test counter",
        "count",
        config,
    );
    defer counter.deinit();

    // Test basic properties
    try testing.expectEqualStrings("test.counter", counter.getName());
    try testing.expect(counter.enabled());

    // Test callback registration
    var state = TestState{};
    const callback = createTypeErasedCallback(i64, TestState, testCallback, &state);
    const handle = counter.registerCallback(callback);
    defer handle.unregister();

    // Test collection
    const metrics = try counter.collect(allocator);
    defer allocator.free(metrics);

    try testing.expect(metrics.len > 0);
    try testing.expectEqual(@as(u32, 1), state.call_count);

    // Verify the measurement
    const measurement = metrics[0];
    try testing.expectEqual(@as(i64, 42), measurement.value.i64_sum);
}

test "SdkObservableGauge basic functionality" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var gauge = SdkObservableGauge(f64).init(
        allocator,
        "test.gauge",
        "Test gauge",
        "units",
        config,
    );
    defer gauge.deinit();

    try testing.expectEqualStrings("test.gauge", gauge.getName());
    try testing.expect(gauge.enabled());

    var state = TestState{};
    const callback = createTypeErasedCallback(f64, TestState, testCallbackF64, &state);
    const handle = gauge.registerCallback(callback);
    defer handle.unregister();

    const metrics = try gauge.collect(allocator);
    defer allocator.free(metrics);

    try testing.expect(metrics.len > 0);
    try testing.expectEqual(@as(f64, 42.5), metrics[0].value.f64_sum);
}

test "SdkObservableUpDownCounter basic functionality" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var updown = SdkObservableUpDownCounter(i64).init(
        allocator,
        "test.updown",
        "Test updown",
        "count",
        config,
    );
    defer updown.deinit();

    try testing.expectEqualStrings("test.updown", updown.getName());
    try testing.expect(updown.enabled());

    var state = TestState{ .value = -15 };
    const callback = createTypeErasedCallback(i64, TestState, testCallback, &state);
    const handle = updown.registerCallback(callback);
    defer handle.unregister();

    const metrics = try updown.collect(allocator);
    defer allocator.free(metrics);

    try testing.expect(metrics.len > 0);
    try testing.expectEqual(@as(i64, -15), metrics[0].value.i64_sum);
}

test "multiple callback registration and execution" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.multi",
        "Test multi",
        "count",
        config,
    );
    defer counter.deinit();

    // Register multiple callbacks
    var state1 = TestState{ .value = 100 };
    var state2 = TestState{ .value = 200 };

    const callback1 = createTypeErasedCallback(i64, TestState, testCallback, &state1);
    const callback2 = createTypeErasedCallback(i64, TestState, testCallback, &state2);
    const callback3 = TypeErasedCallback(i64){ .stateless = .{ .callback_fn = testCallbackNoState } };

    const handle1 = counter.registerCallback(callback1);
    const handle2 = counter.registerCallback(callback2);
    const handle3 = counter.registerCallback(callback3);

    defer {
        handle1.unregister();
        handle2.unregister();
        handle3.unregister();
    }

    // Collect and verify all callbacks were executed
    const metrics = try counter.collect(allocator);
    defer allocator.free(metrics);

    try testing.expect(metrics.len >= 3); // At least 3 measurements
    try testing.expectEqual(@as(u32, 1), state1.call_count);
    try testing.expectEqual(@as(u32, 1), state2.call_count);
}

test "callback unregistration" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.unreg",
        "Test unregister",
        "count",
        config,
    );
    defer counter.deinit();

    var state = TestState{};
    const callback = createTypeErasedCallback(i64, TestState, testCallback, &state);
    const handle = counter.registerCallback(callback);

    // First collection should execute callback
    {
        const metrics = try counter.collect(allocator);
        defer allocator.free(metrics);
        try testing.expect(metrics.len > 0);
        try testing.expectEqual(@as(u32, 1), state.call_count);
    }

    // Unregister callback
    handle.unregister();

    // Second collection should not execute callback
    {
        const metrics = try counter.collect(allocator);
        defer allocator.free(metrics);
        try testing.expectEqual(@as(usize, 0), metrics.len); // No measurements
        try testing.expectEqual(@as(u32, 1), state.call_count); // Count unchanged
    }
}

test "multiple measurements from single callback" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var gauge = SdkObservableGauge(i64).init(
        allocator,
        "test.multi.measurements",
        "Test multiple measurements",
        "count",
        config,
    );
    defer gauge.deinit();

    var state = TestState{ .value = 50 };
    const callback = createTypeErasedCallback(i64, TestState, testCallbackMultiple, &state);
    const handle = gauge.registerCallback(callback);
    defer handle.unregister();

    const metrics = try gauge.collect(allocator);
    defer allocator.free(metrics);

    // Should have 2 measurements from the callback
    try testing.expectEqual(@as(usize, 2), metrics.len);
    try testing.expectEqual(@as(i64, 50), metrics[0].value.i64_sum);
    try testing.expectEqual(@as(i64, 60), metrics[1].value.i64_sum);
}

test "callback error handling policies" {
    const allocator = std.testing.allocator;

    // Test fail_fast policy
    {
        const config = AsyncInstrumentConfig{
            .error_policy = .fail_fast,
            .track_callback_metrics = true,
        };
        var counter = SdkObservableCounter(i64).init(
            allocator,
            "test.error.fail",
            "Test error fail",
            "count",
            config,
        );
        defer counter.deinit();

        var state = TestState{ .should_error = true };
        const callback = createTypeErasedCallback(i64, TestState, testCallback, &state);
        const handle = counter.registerCallback(callback);
        defer handle.unregister();

        const metrics = try counter.collect(allocator);
        defer allocator.free(metrics);

        // Should handle the error according to policy
        try testing.expectEqual(@as(usize, 0), metrics.len);
    }

    // Test silent_ignore policy
    {
        const config = AsyncInstrumentConfig{
            .error_policy = .silent_ignore,
            .track_callback_metrics = true,
        };
        var counter = SdkObservableCounter(i64).init(
            allocator,
            "test.error.ignore",
            "Test error ignore",
            "count",
            config,
        );
        defer counter.deinit();

        var error_state = TestState{ .should_error = true };
        var good_state = TestState{ .value = 123 };

        const error_callback = createTypeErasedCallback(i64, TestState, testCallback, &error_state);
        const good_callback = createTypeErasedCallback(i64, TestState, testCallback, &good_state);

        const error_handle = counter.registerCallback(error_callback);
        const good_handle = counter.registerCallback(good_callback);
        defer {
            error_handle.unregister();
            good_handle.unregister();
        }

        const metrics = try counter.collect(allocator);
        defer allocator.free(metrics);

        // Should have measurement from good callback, ignore error callback
        try testing.expect(metrics.len > 0);
        try testing.expectEqual(@as(i64, 123), metrics[0].value.i64_sum);
    }
}

test "callback metrics tracking" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig{
        .track_callback_metrics = true,
    };
    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.metrics",
        "Test metrics",
        "count",
        config,
    );
    defer counter.deinit();

    var state = TestState{};
    const callback = createTypeErasedCallback(i64, TestState, testCallback, &state);
    const handle = counter.registerCallback(callback);
    defer handle.unregister();

    // Execute multiple collections to generate metrics
    for (0..3) |_| {
        const metrics = try counter.collect(allocator);
        allocator.free(metrics);
    }

    // Check instrument metrics
    const instrument_metrics = counter.getInstrumentMetrics();
    try testing.expect(instrument_metrics.total_executions >= 3);
    try testing.expect(instrument_metrics.total_execution_time_ns > 0);

    // Check individual callback metrics
    const all_callback_metrics = try counter.getAllCallbackMetrics(allocator);
    defer allocator.free(all_callback_metrics);
    try testing.expect(all_callback_metrics.len > 0);

    const callback_metrics = all_callback_metrics[0];
    try testing.expect(callback_metrics.total_executions >= 3);
}

test "async instrument configuration variants" {
    // Test default configuration
    {
        const config = AsyncInstrumentConfig.default();
        try testing.expectEqual(CallbackErrorPolicy.log_continue, config.error_policy);
        try testing.expectEqual(@as(?usize, null), config.max_measurements_per_callback);
        try testing.expectEqual(false, config.warn_on_no_measurements);
        try testing.expectEqual(true, config.track_callback_metrics);
    }

    // Test production configuration
    {
        const config = AsyncInstrumentConfig.production();
        try testing.expectEqual(CallbackErrorPolicy.silent_ignore, config.error_policy);
        try testing.expectEqual(@as(?usize, 100), config.max_measurements_per_callback);
        try testing.expectEqual(false, config.warn_on_no_measurements);
        try testing.expectEqual(false, config.track_callback_metrics);
    }

    // Test development configuration
    {
        const config = AsyncInstrumentConfig.development();
        try testing.expectEqual(CallbackErrorPolicy.log_continue, config.error_policy);
        try testing.expectEqual(@as(?usize, 10), config.max_measurements_per_callback);
        try testing.expectEqual(true, config.warn_on_no_measurements);
        try testing.expectEqual(true, config.track_callback_metrics);
    }
}

test "callback metrics functionality" {
    const allocator = std.testing.allocator;

    var metrics = CallbackMetrics{};
    defer metrics.deinit(allocator);

    // Test recording execution
    metrics.recordExecution(1000);
    metrics.recordExecution(2000);
    metrics.recordExecution(500);

    try testing.expectEqual(@as(u64, 3), metrics.total_executions);
    try testing.expectEqual(@as(u64, 3500), metrics.total_execution_time_ns);
    try testing.expectEqual(@as(u64, 2000), metrics.max_execution_time_ns);
    try testing.expectEqual(@as(u64, 500), metrics.min_execution_time_ns);

    // Test average calculation
    const avg = metrics.getAverageExecutionTimeNs();
    try testing.expectEqual(@as(u64, 1166), avg); // 3500 / 3 = 1166

    // Test error recording
    metrics.recordError(allocator, "Test error", 123, "test.instrument");
    try testing.expectEqual(@as(u64, 1), metrics.error_count);
    try testing.expect(metrics.last_error != null);
}

test "empty callback collection" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.empty",
        "Test empty",
        "count",
        config,
    );
    defer counter.deinit();

    // Collect without any registered callbacks
    const metrics = try counter.collect(allocator);
    defer allocator.free(metrics);

    try testing.expectEqual(@as(usize, 0), metrics.len);
}

test "concurrent callback registration" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig.default();
    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.concurrent",
        "Test concurrent",
        "count",
        config,
    );
    defer counter.deinit();

    // Register and unregister callbacks multiple times
    for (0..5) |i| {
        var state = TestState{ .value = @intCast(i) };
        const callback = createTypeErasedCallback(i64, TestState, testCallback, &state);
        const handle = counter.registerCallback(callback);

        // Immediately unregister
        handle.unregister();
    }

    // Collection should work without issues
    const metrics = try counter.collect(allocator);
    defer allocator.free(metrics);
    try testing.expectEqual(@as(usize, 0), metrics.len);
}
