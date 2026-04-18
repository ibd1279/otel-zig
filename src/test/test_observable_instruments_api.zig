//! Tests for Observable Instruments API
//!
//! This module tests the API-level functionality of observable instruments,
//! including callback registration, type erasure, and ObservableResult interface.

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");

fn milliTimestamp() i64 {
    const ts = std.Io.Clock.real.now(std.testing.io) catch std.Io.Timestamp.zero;
    return @divTrunc(ts.nanoseconds, std.time.ns_per_ms);
}

const ObservableCounter = otel_api.metrics.ObservableCounter;
const ObservableGauge = otel_api.metrics.ObservableGauge;
const ObservableUpDownCounter = otel_api.metrics.ObservableUpDownCounter;
const ObservableResult = otel_api.metrics.ObservableResult;
const ObservableCallback = otel_api.metrics.ObservableCallback;
const ObservableCallbackNoState = otel_api.metrics.ObservableCallbackNoState;
const CallbackHandle = otel_api.metrics.CallbackHandle;
const TypeErasedCallback = otel_api.metrics.TypeErasedCallback;
const createTypeErasedCallback = otel_api.metrics.createTypeErasedCallback;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;

test "ObservableResult basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ObservableResult(i64).init(allocator, null);
    defer result.deinit();

    try result.observeValue(42);
    try result.observeSimple(100, &[_]AttributeKeyValue{
        .{ .key = "test", .value = .{ .string = "value" } },
    });

    try testing.expectEqual(@as(usize, 2), result.measurements.items.len);
    try testing.expectEqual(@as(i64, 42), result.measurements.items[0].value);
    try testing.expectEqual(@as(i64, 100), result.measurements.items[1].value);
}

test "ObservableResult with attributes and timestamps" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const timestamp: i64 = @intCast(milliTimestamp());
    var result = ObservableResult(f64).init(allocator, timestamp);
    defer result.deinit();

    const attrs = [_]AttributeKeyValue{
        .{ .key = "component", .value = .{ .string = "cpu" } },
        .{ .key = "core", .value = .{ .int = 0 } },
    };

    try result.observe(75.5, &attrs, timestamp + 1000);
    try result.observeSimple(80.0, &attrs);

    try testing.expectEqual(@as(usize, 2), result.measurements.items.len);
    try testing.expectEqual(@as(f64, 75.5), result.measurements.items[0].value);
    try testing.expectEqual(@as(f64, 80.0), result.measurements.items[1].value);
    try testing.expectEqual(timestamp + 1000, result.measurements.items[0].timestamp.?);
    try testing.expectEqual(timestamp, result.measurements.items[1].timestamp.?);
}

test "noop observable instruments" {
    // Test that noop instruments return false for enabled() and don't crash
    const counter = ObservableCounter(i64){ .noop = "test_counter" };
    const gauge = ObservableGauge(f64){ .noop = "test_gauge" };
    const updown = ObservableUpDownCounter(i64){ .noop = "test_updown" };

    try testing.expectEqual(false, counter.enabled());
    try testing.expectEqual(false, gauge.enabled());
    try testing.expectEqual(false, updown.enabled());

    try testing.expectEqualStrings("test_counter", counter.getName());
    try testing.expectEqualStrings("test_gauge", gauge.getName());
    try testing.expectEqualStrings("test_updown", updown.getName());
}

test "callback handle noop functionality" {
    var handle = CallbackHandle.noop;
    try testing.expect(handle.instrument_ptr == null);
    try testing.expect(handle.unregister_fn == null);
    try testing.expectEqual(@as(u64, 0), handle.callback_id);

    // Should not crash
    handle.unregister();
}

test "callback handle initialization" {
    var dummy_instrument: i32 = 123;
    const unregister_fn = struct {
        fn call(instrument_ptr: *anyopaque, callback_id: u64) void {
            _ = instrument_ptr;
            _ = callback_id;
        }
    }.call;

    var handle = CallbackHandle.init(&dummy_instrument, unregister_fn, 42);
    try testing.expect(handle.instrument_ptr != null);
    try testing.expect(handle.unregister_fn != null);
    try testing.expectEqual(@as(u64, 42), handle.callback_id);

    // Should not crash
    handle.unregister();
}

test "type erased callback creation - stateful" {
    var state: i32 = 123;
    const callback = struct {
        fn call(result: *ObservableResult(i64), s: *i32) void {
            _ = result;
            _ = s;
        }
    }.call;

    const erased = createTypeErasedCallback(i64, i32, callback, &state);
    try testing.expect(erased.state != null);
    try testing.expect(erased.has_state);
    try testing.expect(@intFromPtr(erased.callback_fn) != 0);
}

test "type erased callback creation - stateless" {
    const callback = struct {
        fn call(result: *ObservableResult(i64)) void {
            _ = result;
        }
    }.call;

    const erased = TypeErasedCallback(i64){ .stateless = .{ .callback_fn = callback } };
    try testing.expect(erased.state == null);
    try testing.expect(!erased.has_state);
    try testing.expect(@intFromPtr(erased.callback_fn) != 0);
}

test "observable instrument compile-time type checking" {
    // These should compile fine
    const counter_i64 = ObservableCounter(i64){ .noop = "test" };
    const counter_f64 = ObservableCounter(f64){ .noop = "test" };
    const gauge_i64 = ObservableGauge(i64){ .noop = "test" };
    const gauge_f64 = ObservableGauge(f64){ .noop = "test" };
    const updown_i64 = ObservableUpDownCounter(i64){ .noop = "test" };
    const updown_f64 = ObservableUpDownCounter(f64){ .noop = "test" };

    _ = counter_i64;
    _ = counter_f64;
    _ = gauge_i64;
    _ = gauge_f64;
    _ = updown_i64;
    _ = updown_f64;

    // This would fail at compile time:
    // var counter_bad = ObservableCounter(u32){ .noop = "test" };
}

test "observable result multiple observations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ObservableResult(i64).init(allocator, null);
    defer result.deinit();

    // Simulate multiple CPU cores
    const cpu_attrs = [_]AttributeKeyValue{
        .{ .key = "cpu", .value = .{ .int = 0 } },
    };
    const cpu1_attrs = [_]AttributeKeyValue{
        .{ .key = "cpu", .value = .{ .int = 1 } },
    };
    const cpu2_attrs = [_]AttributeKeyValue{
        .{ .key = "cpu", .value = .{ .int = 2 } },
    };

    try result.observeSimple(1000, &cpu_attrs);
    try result.observeSimple(2000, &cpu1_attrs);
    try result.observeSimple(1500, &cpu2_attrs);

    try testing.expectEqual(@as(usize, 3), result.measurements.items.len);
    try testing.expectEqual(@as(i64, 1000), result.measurements.items[0].value);
    try testing.expectEqual(@as(i64, 2000), result.measurements.items[1].value);
    try testing.expectEqual(@as(i64, 1500), result.measurements.items[2].value);
}

test "noop observable instruments callback registration" {
    const counter = ObservableCounter(i64){ .noop = "test" };

    // Should work without crashing
    var state: i32 = 42;
    const callback = struct {
        fn call(result: *ObservableResult(i64), s: *i32) void {
            _ = result;
            _ = s;
        }
    }.call;

    const handle = try counter.registerCallback(i32, callback, &state);
    try testing.expect(handle.instrument_ptr == null);
    handle.unregister(); // Should not crash

    // Test stateless callback
    const callback_no_state = struct {
        fn call(result: *ObservableResult(i64)) void {
            _ = result;
        }
    }.call;

    const handle_no_state = try counter.registerCallbackNoState(callback_no_state);
    try testing.expect(handle_no_state.instrument_ptr == null);
    handle_no_state.unregister(); // Should not crash
}

test "observable result empty measurements" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ObservableResult(f64).init(allocator, null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.measurements.items.len);
}

test "observable result with zero values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ObservableResult(f64).init(allocator, null);
    defer result.deinit();

    try result.observeValue(0.0);
    try result.observeValue(-0.0);

    try testing.expectEqual(@as(usize, 2), result.measurements.items.len);
    try testing.expectEqual(@as(f64, 0.0), result.measurements.items[0].value);
    try testing.expectEqual(@as(f64, -0.0), result.measurements.items[1].value);
}

test "observable result with large values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ObservableResult(i64).init(allocator, null);
    defer result.deinit();

    const large_value = std.math.maxInt(i64);
    const small_value = std.math.minInt(i64);

    try result.observeValue(large_value);
    try result.observeValue(small_value);

    try testing.expectEqual(@as(usize, 2), result.measurements.items.len);
    try testing.expectEqual(large_value, result.measurements.items[0].value);
    try testing.expectEqual(small_value, result.measurements.items[1].value);
}

// Integration test demonstrating callback types
test "callback type compatibility" {
    // Test that different callback signatures work with type erasure
    const TestState = struct {
        value: i64,
    };

    var state = TestState{ .value = 42 };

    // Stateful callback
    const stateful_callback = struct {
        fn call(result: *ObservableResult(i64), s: *TestState) void {
            _ = result;
            _ = s;
        }
    }.call;

    const erased_stateful = createTypeErasedCallback(i64, TestState, stateful_callback, &state);
    try testing.expect(erased_stateful.has_state);
    try testing.expect(erased_stateful.state != null);

    // Stateless callback
    const stateless_callback = struct {
        fn call(result: *ObservableResult(i64)) void {
            _ = result;
        }
    }.call;

    const erased_stateless = TypeErasedCallback(i64){ .stateless = .{ .callback_fn = stateless_callback } };
    try testing.expect(!erased_stateless.has_state);
    try testing.expect(erased_stateless.state == null);
}
