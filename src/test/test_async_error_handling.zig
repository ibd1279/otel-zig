//! Tests for Async Instruments Error Handling Integration
//!
//! This module tests the error handling integration of observable instruments
//! with the OpenTelemetry error handler system, including callback error reporting,
//! policy enforcement, and performance monitoring.

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const ObservableResult = otel_api.metrics.ObservableResult;
const TypeErasedCallback = otel_api.metrics.TypeErasedCallback;
const createTypeErasedCallback = otel_api.metrics.createTypeErasedCallback;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const ErrorInfo = otel_api.common.ErrorInfo;
const Component = otel_api.common.Component;
const ErrorType = otel_api.common.ErrorType;
const setGlobalErrorHandler = otel_api.common.setGlobalErrorHandler;

const AsyncInstrumentConfig = otel_sdk.metrics.AsyncInstrumentConfig;
const CallbackErrorPolicy = otel_sdk.metrics.CallbackErrorPolicy;
const SdkObservableCounter = otel_sdk.metrics.SdkObservableCounter;

// Test state for capturing error reports
const ErrorCapture = struct {
    var captured_errors: std.ArrayList(ErrorInfo) = undefined;
    var allocator: std.mem.Allocator = undefined;
    var mutex: std.atomic.Mutex = .unlocked;

    fn init(alloc: std.mem.Allocator) void {
        allocator = alloc;
        captured_errors = std.ArrayList(ErrorInfo).init(alloc);
    }

    fn deinit() void {
        captured_errors.deinit();
    }

    fn reset() void {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        captured_errors.clearRetainingCapacity();
    }

    fn captureError(info: ErrorInfo, alloc: ?std.mem.Allocator) void {
        _ = alloc;
        while (!mutex.tryLock()) {}
        defer mutex.unlock();

        // Clone the error info for our test
        const cloned_info = ErrorInfo{
            .component = info.component,
            .operation = allocator.dupe(u8, info.operation) catch "unknown",
            .error_type = info.error_type,
            .message = allocator.dupe(u8, info.message) catch "unknown",
            .context = if (info.context) |ctx| allocator.dupe(u8, ctx) catch null else null,
            .source_error = info.source_error,
        };
        captured_errors.append(cloned_info) catch {};
    }

    fn getErrorCount() usize {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        return captured_errors.items.len;
    }

    fn getLastError() ?ErrorInfo {
        while (!mutex.tryLock()) {}
        defer mutex.unlock();
        if (captured_errors.items.len == 0) return null;
        return captured_errors.items[captured_errors.items.len - 1];
    }
};

// Test state for callbacks
const TestState = struct {
    should_produce_no_measurements: bool = false,
    should_produce_too_many: bool = false,
    measurement_count: u32 = 0,
};

// Callback that produces no measurements when requested
fn noMeasurementsCallback(result: *ObservableResult(i64), state: *TestState) void {
    state.measurement_count += 1;
    if (state.should_produce_no_measurements) {
        // Don't call result.observe() - this should trigger a warning
        return;
    }
    result.observeValue(42) catch {};
}

// Callback that produces too many measurements when requested
fn tooManyMeasurementsCallback(result: *ObservableResult(i64), state: *TestState) void {
    state.measurement_count += 1;
    if (state.should_produce_too_many) {
        // Produce way too many measurements
        for (0..20) |i| {
            result.observeValue(@intCast(i)) catch {};
        }
        return;
    }
    result.observeValue(42) catch {};
}

test "callback error reporting integration" {
    const allocator = std.testing.allocator;

    // Initialize error capture
    ErrorCapture.init(allocator);
    defer ErrorCapture.deinit();

    // Set our custom error handler
    const original_handler = otel_api.common.getGlobalErrorHandler();
    defer if (original_handler) |handler| setGlobalErrorHandler(handler);
    setGlobalErrorHandler(ErrorCapture.captureError);

    ErrorCapture.reset();

    // Create an observable counter with development config (warns on no measurements)
    const config = AsyncInstrumentConfig{
        .error_policy = .log_continue,
        .warn_on_no_measurements = true,
        .track_callback_metrics = true,
        .max_measurements_per_callback = 5,
    };

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.error.reporting",
        "Test error reporting",
        "count",
        config,
    );
    defer counter.deinit();

    // Test 1: No measurements produced
    {
        ErrorCapture.reset();
        var state = TestState{ .should_produce_no_measurements = true };
        const callback = createTypeErasedCallback(i64, TestState, noMeasurementsCallback, &state);
        const handle = counter.registerCallback(callback);
        defer handle.unregister();

        // Collect metrics - should trigger warning
        const metrics = try counter.collect(allocator);
        defer allocator.free(metrics);

        // Should have captured an error about no measurements
        try testing.expect(ErrorCapture.getErrorCount() > 0);
        const last_error = ErrorCapture.getLastError().?;
        try testing.expectEqual(Component.meter, last_error.component);
        try testing.expectEqual(ErrorType.callback, last_error.error_type);
        try testing.expect(std.mem.find(u8, last_error.message, "no measurements") != null);
    }

    // Test 2: Too many measurements produced
    {
        ErrorCapture.reset();
        var state = TestState{ .should_produce_too_many = true };
        const callback = createTypeErasedCallback(i64, TestState, tooManyMeasurementsCallback, &state);
        const handle = counter.registerCallback(callback);
        defer handle.unregister();

        // Collect metrics - should trigger limit warning
        const metrics = try counter.collect(allocator);
        defer allocator.free(metrics);

        // Should have captured an error about too many measurements
        try testing.expect(ErrorCapture.getErrorCount() > 0);
        const last_error = ErrorCapture.getLastError().?;
        try testing.expectEqual(Component.meter, last_error.component);
        try testing.expectEqual(ErrorType.callback, last_error.error_type);
        try testing.expect(std.mem.find(u8, last_error.message, "too many measurements") != null);
    }
}

test "callback error policy enforcement" {
    const allocator = std.testing.allocator;

    // Initialize error capture
    ErrorCapture.init(allocator);
    defer ErrorCapture.deinit();

    // Set our custom error handler
    const original_handler = otel_api.common.getGlobalErrorHandler();
    defer if (original_handler) |handler| setGlobalErrorHandler(handler);
    setGlobalErrorHandler(ErrorCapture.captureError);

    // Test different error policies
    const policies = [_]CallbackErrorPolicy{ .fail_fast, .log_continue, .silent_ignore };

    for (policies) |policy| {
        ErrorCapture.reset();

        const config = AsyncInstrumentConfig{
            .error_policy = policy,
            .warn_on_no_measurements = true,
            .track_callback_metrics = true,
        };

        var counter = SdkObservableCounter(i64).init(
            allocator,
            "test.policy.enforcement",
            "Test policy enforcement",
            "count",
            config,
        );
        defer counter.deinit();

        var state = TestState{ .should_produce_no_measurements = true };
        const callback = createTypeErasedCallback(i64, TestState, noMeasurementsCallback, &state);
        const handle = counter.registerCallback(callback);
        defer handle.unregister();

        // Collect metrics
        const metrics = try counter.collect(allocator);
        defer allocator.free(metrics);

        // All policies should report the error for no measurements warning
        try testing.expect(ErrorCapture.getErrorCount() > 0);

        // Verify error was reported with correct details
        const last_error = ErrorCapture.getLastError().?;
        try testing.expectEqual(Component.meter, last_error.component);
        try testing.expectEqual(ErrorType.callback, last_error.error_type);
        try testing.expectEqualStrings("executeCallback", last_error.operation);
    }
}

test "callback metrics tracking with error reporting" {
    const allocator = std.testing.allocator;

    // Initialize error capture
    ErrorCapture.init(allocator);
    defer ErrorCapture.deinit();

    // Set our custom error handler
    const original_handler = otel_api.common.getGlobalErrorHandler();
    defer if (original_handler) |handler| setGlobalErrorHandler(handler);
    setGlobalErrorHandler(ErrorCapture.captureError);

    ErrorCapture.reset();

    const config = AsyncInstrumentConfig{
        .error_policy = .log_continue,
        .track_callback_metrics = true,
        .warn_on_no_measurements = true,
    };

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.metrics.tracking",
        "Test metrics tracking",
        "count",
        config,
    );
    defer counter.deinit();

    var state = TestState{ .should_produce_no_measurements = true };
    const callback = createTypeErasedCallback(i64, TestState, noMeasurementsCallback, &state);
    const handle = counter.registerCallback(callback);
    defer handle.unregister();

    // Execute multiple collections to generate metrics and errors
    for (0..3) |_| {
        const metrics = try counter.collect(allocator);
        allocator.free(metrics);
    }

    // Should have captured multiple errors
    try testing.expect(ErrorCapture.getErrorCount() >= 3);

    // Check that callback metrics were tracked
    const all_callback_metrics = try counter.getAllCallbackMetrics(allocator);
    defer allocator.free(all_callback_metrics);

    try testing.expect(all_callback_metrics.len > 0);
    const callback_metrics = all_callback_metrics[0];
    try testing.expect(callback_metrics.total_executions >= 3);
    try testing.expect(callback_metrics.error_count >= 3);
    try testing.expect(callback_metrics.last_error != null);
}

test "error context information" {
    const allocator = std.testing.allocator;

    // Initialize error capture
    ErrorCapture.init(allocator);
    defer ErrorCapture.deinit();

    // Set our custom error handler
    const original_handler = otel_api.common.getGlobalErrorHandler();
    defer if (original_handler) |handler| setGlobalErrorHandler(handler);
    setGlobalErrorHandler(ErrorCapture.captureError);

    ErrorCapture.reset();

    const config = AsyncInstrumentConfig{
        .error_policy = .log_continue,
        .track_callback_metrics = true,
        .warn_on_no_measurements = true,
    };

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "my.test.instrument",
        "My test instrument",
        "count",
        config,
    );
    defer counter.deinit();

    var state = TestState{ .should_produce_no_measurements = true };
    const callback = createTypeErasedCallback(i64, TestState, noMeasurementsCallback, &state);
    const handle = counter.registerCallback(callback);
    defer handle.unregister();

    // Collect metrics to trigger error
    const metrics = try counter.collect(allocator);
    defer allocator.free(metrics);

    // Verify error context includes instrument name
    try testing.expect(ErrorCapture.getErrorCount() > 0);
    const last_error = ErrorCapture.getLastError().?;
    try testing.expect(last_error.context != null);
    try testing.expect(std.mem.find(u8, last_error.context.?, "my.test.instrument") != null);
}

test "callback performance monitoring" {
    const allocator = std.testing.allocator;

    const config = AsyncInstrumentConfig{
        .track_callback_metrics = true,
    };

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.performance",
        "Test performance",
        "count",
        config,
    );
    defer counter.deinit();

    // Normal callback that should execute successfully
    var state = TestState{};
    const callback = createTypeErasedCallback(i64, TestState, noMeasurementsCallback, &state);
    const handle = counter.registerCallback(callback);
    defer handle.unregister();

    // Execute several collections to measure performance
    for (0..5) |_| {
        const metrics = try counter.collect(allocator);
        allocator.free(metrics);
    }

    // Verify performance metrics were recorded
    const instrument_metrics = counter.getInstrumentMetrics();
    try testing.expect(instrument_metrics.total_executions >= 5);
    try testing.expect(instrument_metrics.total_execution_time_ns > 0);
    try testing.expect(instrument_metrics.max_execution_time_ns > 0);
    try testing.expect(instrument_metrics.min_execution_time_ns > 0);
    try testing.expect(instrument_metrics.getAverageExecutionTimeNs() > 0);

    // Check individual callback metrics
    const all_callback_metrics = try counter.getAllCallbackMetrics(allocator);
    defer allocator.free(all_callback_metrics);

    try testing.expect(all_callback_metrics.len > 0);
    const callback_metrics = all_callback_metrics[0];
    try testing.expect(callback_metrics.total_executions >= 5);
    try testing.expect(callback_metrics.total_execution_time_ns > 0);
}

test "multiple callbacks with different error behaviors" {
    const allocator = std.testing.allocator;

    // Initialize error capture
    ErrorCapture.init(allocator);
    defer ErrorCapture.deinit();

    // Set our custom error handler
    const original_handler = otel_api.common.getGlobalErrorHandler();
    defer if (original_handler) |handler| setGlobalErrorHandler(handler);
    setGlobalErrorHandler(ErrorCapture.captureError);

    ErrorCapture.reset();

    const config = AsyncInstrumentConfig{
        .error_policy = .log_continue,
        .track_callback_metrics = true,
        .warn_on_no_measurements = true,
        .max_measurements_per_callback = 5,
    };

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.multiple.callbacks",
        "Test multiple callbacks",
        "count",
        config,
    );
    defer counter.deinit();

    // Register multiple callbacks with different behaviors
    var good_state = TestState{};
    var no_measurements_state = TestState{ .should_produce_no_measurements = true };
    var too_many_state = TestState{ .should_produce_too_many = true };

    const good_callback = createTypeErasedCallback(i64, TestState, noMeasurementsCallback, &good_state);
    const no_measurements_callback = createTypeErasedCallback(i64, TestState, noMeasurementsCallback, &no_measurements_state);
    const too_many_callback = createTypeErasedCallback(i64, TestState, tooManyMeasurementsCallback, &too_many_state);

    const good_handle = counter.registerCallback(good_callback);
    const no_measurements_handle = counter.registerCallback(no_measurements_callback);
    const too_many_handle = counter.registerCallback(too_many_callback);

    defer {
        good_handle.unregister();
        no_measurements_handle.unregister();
        too_many_handle.unregister();
    }

    // Collect metrics - should trigger multiple errors
    const metrics = try counter.collect(allocator);
    defer allocator.free(metrics);

    // Should have captured multiple errors (no measurements + too many measurements)
    try testing.expect(ErrorCapture.getErrorCount() >= 2);

    // Verify all callbacks were executed despite errors
    try testing.expectEqual(@as(u32, 1), good_state.measurement_count);
    try testing.expectEqual(@as(u32, 1), no_measurements_state.measurement_count);
    try testing.expectEqual(@as(u32, 1), too_many_state.measurement_count);

    // Should have some measurements from the good callback and truncated measurements from the too_many callback
    try testing.expect(metrics.len > 0);
}
