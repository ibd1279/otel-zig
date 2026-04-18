//! Integration tests for Observable Instruments API with SDK
//!
//! This module tests the full integration of observable instruments from API
//! to SDK implementation, including meter creation, callback registration,
//! and metric collection.

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const ObservableCounter = otel_api.metrics.ObservableCounter;
const ObservableGauge = otel_api.metrics.ObservableGauge;
const ObservableUpDownCounter = otel_api.metrics.ObservableUpDownCounter;
const ObservableResult = otel_api.metrics.ObservableResult;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const InstrumentationScope = otel_api.common.InstrumentationScope;
const Resource = otel_sdk.resource.Resource;

const BasicMeterProvider = otel_sdk.metrics.BasicMeterProvider;
// Import BasicMeter directly from the basic_provider file since it's not exported
const BasicMeter = @import("../sdk/metrics/basic_provider.zig").BasicMeter;

// Test state for callbacks
const TestState = struct {
    counter_value: i64 = 100,
    gauge_value: f64 = 42.5,
    updown_value: i64 = -10,
};

// Callback functions
fn counterCallback(result: *ObservableResult(i64), state: *TestState) void {
    const attrs = [_]AttributeKeyValue{
        .{ .key = "test", .value = .{ .string = "counter" } },
    };
    result.observe(state.counter_value, &attrs, null) catch {};
}

fn gaugeCallback(result: *ObservableResult(f64), state: *TestState) void {
    const attrs = [_]AttributeKeyValue{
        .{ .key = "test", .value = .{ .string = "gauge" } },
    };
    result.observe(state.gauge_value, &attrs, null) catch {};
}

fn updownCallback(result: *ObservableResult(i64), state: *TestState) void {
    const attrs = [_]AttributeKeyValue{
        .{ .key = "test", .value = .{ .string = "updown" } },
    };
    result.observe(state.updown_value, &attrs, null) catch {};
}

fn simpleCallback(result: *ObservableResult(i64)) void {
    result.observeValue(999) catch {};
}

test "observable counter API to SDK integration" {
    const allocator = std.testing.allocator;

    // Create meter provider with empty resource to avoid ownership issues
    var provider = BasicMeterProvider.init(allocator, Resource.empty);
    defer provider.deinit();

    // Create meter
    const scope = try InstrumentationScope.initSimple("test.observable", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create observable counter using the API
    var counter = try meter.createObservableCounter(i64, "test.counter", "Test counter", "count");
    try testing.expect(counter.enabled());
    try testing.expectEqualStrings("test.counter", counter.getName());

    // Register callback
    var state = TestState{};
    const handle = try counter.registerCallback(TestState, counterCallback, &state);
    defer handle.unregister();

    // Get the BasicMeter for collection
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics
    const metrics = try basic_meter.collectMetrics(allocator);
    defer {
        for (metrics) |metric| {
            allocator.free(metric.data_points);
        }
        allocator.free(metrics);
    }

    // Verify we got metric data
    try testing.expect(metrics.len > 0);

    // Find our counter metric
    var found_counter = false;
    for (metrics) |metric| {
        if (std.mem.eql(u8, metric.name, "test.counter")) {
            found_counter = true;
            try testing.expect(metric.data_points.len > 0);
            const data_point = metric.data_points[0];
            switch (data_point.value) {
                .i64_sum => |value| try testing.expectEqual(@as(i64, 100), value),
                .i64_gauge => |value| try testing.expectEqual(@as(i64, 100), value),
                else => try testing.expect(false), // Should be i64
            }
        }
    }
    try testing.expect(found_counter);
}

test "observable gauge API to SDK integration" {
    const allocator = std.testing.allocator;

    // Create meter provider with empty resource to avoid ownership issues
    var provider = BasicMeterProvider.init(allocator, Resource.empty);
    defer provider.deinit();

    // Create meter
    const scope = try InstrumentationScope.initSimple("test.observable", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create observable gauge using the API
    var gauge = try meter.createObservableGauge(f64, "test.gauge", "Test gauge", "units");
    try testing.expect(gauge.enabled());
    try testing.expectEqualStrings("test.gauge", gauge.getName());

    // Register callback
    var state = TestState{};
    const handle = try gauge.registerCallback(TestState, gaugeCallback, &state);
    defer handle.unregister();

    // Get the BasicMeter for collection
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics
    const metrics = try basic_meter.collectMetrics(allocator);
    defer {
        for (metrics) |metric| {
            allocator.free(metric.data_points);
        }
        allocator.free(metrics);
    }

    // Find our gauge metric
    var found_gauge = false;
    for (metrics) |metric| {
        if (std.mem.eql(u8, metric.name, "test.gauge")) {
            found_gauge = true;
            try testing.expect(metric.data_points.len > 0);
            const data_point = metric.data_points[0];
            switch (data_point.value) {
                .f64_gauge => |value| try testing.expectEqual(@as(f64, 42.5), value),
                .f64_sum => |value| try testing.expectEqual(@as(f64, 42.5), value),
                else => try testing.expect(false), // Should be f64
            }
        }
    }
    try testing.expect(found_gauge);
}

test "observable updown counter API to SDK integration" {
    const allocator = std.testing.allocator;

    // Create meter provider with empty resource to avoid ownership issues
    var provider = BasicMeterProvider.init(allocator, Resource.empty);
    defer provider.deinit();

    // Create meter
    const scope = try InstrumentationScope.initSimple("test.observable", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create observable updown counter using the API
    var updown = try meter.createObservableUpDownCounter(i64, "test.updown", "Test updown", "count");
    try testing.expect(updown.enabled());
    try testing.expectEqualStrings("test.updown", updown.getName());

    // Register callback
    var state = TestState{};
    const handle = try updown.registerCallback(TestState, updownCallback, &state);
    defer handle.unregister();

    // Get the BasicMeter for collection
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics
    const metrics = try basic_meter.collectMetrics(allocator);
    defer {
        for (metrics) |metric| {
            allocator.free(metric.data_points);
        }
        allocator.free(metrics);
    }

    // Find our updown counter metric
    var found_updown = false;
    for (metrics) |metric| {
        if (std.mem.eql(u8, metric.name, "test.updown")) {
            found_updown = true;
            try testing.expect(metric.data_points.len > 0);
            const data_point = metric.data_points[0];
            switch (data_point.value) {
                .i64_sum => |value| try testing.expectEqual(@as(i64, -10), value),
                .i64_gauge => |value| try testing.expectEqual(@as(i64, -10), value),
                else => try testing.expect(false), // Should be i64
            }
        }
    }
    try testing.expect(found_updown);
}

test "stateless callback API integration" {
    const allocator = std.testing.allocator;

    // Create meter provider with empty resource to avoid ownership issues
    var provider = BasicMeterProvider.init(allocator, Resource.empty);
    defer provider.deinit();

    // Create meter
    const scope = try InstrumentationScope.initSimple("test.observable", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create observable counter using the API
    var counter = try meter.createObservableCounter(i64, "test.simple", "Test simple", "count");
    try testing.expect(counter.enabled());

    // Register stateless callback
    const handle = try counter.registerCallbackNoState(simpleCallback);
    defer handle.unregister();

    // Get the BasicMeter for collection
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics
    const metrics = try basic_meter.collectMetrics(allocator);
    defer {
        for (metrics) |metric| {
            allocator.free(metric.data_points);
        }
        allocator.free(metrics);
    }

    // Find our simple counter metric
    var found_simple = false;
    for (metrics) |metric| {
        if (std.mem.eql(u8, metric.name, "test.simple")) {
            found_simple = true;
            try testing.expect(metric.data_points.len > 0);
            const data_point = metric.data_points[0];
            switch (data_point.value) {
                .i64_sum => |value| try testing.expectEqual(@as(i64, 999), value),
                .i64_gauge => |value| try testing.expectEqual(@as(i64, 999), value),
                else => try testing.expect(false), // Should be i64
            }
        }
    }
    try testing.expect(found_simple);
}

test "multiple observable instruments on same meter" {
    const allocator = std.testing.allocator;

    // Create meter provider with empty resource to avoid ownership issues
    var provider = BasicMeterProvider.init(allocator, Resource.empty);
    defer provider.deinit();

    // Create meter
    const scope = try InstrumentationScope.initSimple("test.observable", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create multiple observable instruments
    var counter = try meter.createObservableCounter(i64, "test.multi.counter", "Multi counter", "count");
    var gauge = try meter.createObservableGauge(f64, "test.multi.gauge", "Multi gauge", "units");
    var updown = try meter.createObservableUpDownCounter(i64, "test.multi.updown", "Multi updown", "count");

    // Register callbacks
    var state = TestState{};
    const counter_handle = try counter.registerCallback(TestState, counterCallback, &state);
    const gauge_handle = try gauge.registerCallback(TestState, gaugeCallback, &state);
    const updown_handle = try updown.registerCallback(TestState, updownCallback, &state);

    defer {
        counter_handle.unregister();
        gauge_handle.unregister();
        updown_handle.unregister();
    }

    // Get the BasicMeter for collection
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics
    const metrics = try basic_meter.collectMetrics(allocator);
    defer {
        for (metrics) |metric| {
            allocator.free(metric.data_points);
        }
        allocator.free(metrics);
    }

    // Should have at least 3 metrics (counter, gauge, updown)
    try testing.expect(metrics.len >= 3);

    // Count how many of our instruments we found
    var found_counter = false;
    var found_gauge = false;
    var found_updown = false;

    for (metrics) |metric| {
        if (std.mem.eql(u8, metric.name, "test.multi.counter")) {
            found_counter = true;
        } else if (std.mem.eql(u8, metric.name, "test.multi.gauge")) {
            found_gauge = true;
        } else if (std.mem.eql(u8, metric.name, "test.multi.updown")) {
            found_updown = true;
        }
    }

    try testing.expect(found_counter);
    try testing.expect(found_gauge);
    try testing.expect(found_updown);
}

test "observable instruments with attributes" {
    const allocator = std.testing.allocator;

    // Create meter provider with empty resource to avoid ownership issues
    var provider = BasicMeterProvider.init(allocator, Resource.empty);
    defer provider.deinit();

    // Create meter
    const scope = try InstrumentationScope.initSimple("test.observable", "1.0.0");
    var meter = try provider.getMeterWithScope(scope);

    // Create observable counter
    var counter = try meter.createObservableCounter(i64, "test.attrs", "Test with attributes", "count");

    // Callback that produces multiple measurements with different attributes
    const multiCallback = struct {
        fn call(result: *ObservableResult(i64), state: *TestState) void {
            _ = state;
            const attrs1 = [_]AttributeKeyValue{
                .{ .key = "component", .value = .{ .string = "cpu" } },
                .{ .key = "core", .value = .{ .int = 0 } },
            };
            const attrs2 = [_]AttributeKeyValue{
                .{ .key = "component", .value = .{ .string = "cpu" } },
                .{ .key = "core", .value = .{ .int = 1 } },
            };
            result.observe(100, &attrs1, null) catch {};
            result.observe(200, &attrs2, null) catch {};
        }
    }.call;

    // Register callback
    var state = TestState{};
    const handle = try counter.registerCallback(TestState, multiCallback, &state);
    defer handle.unregister();

    // Get the BasicMeter for collection
    const basic_meter: *BasicMeter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // Collect metrics
    const metrics = try basic_meter.collectMetrics(allocator);
    defer {
        for (metrics) |metric| {
            allocator.free(metric.data_points);
        }
        allocator.free(metrics);
    }

    // Find our counter metric
    var found_counter = false;
    for (metrics) |metric| {
        if (std.mem.eql(u8, metric.name, "test.attrs")) {
            found_counter = true;
            // Should have 2 data points (one for each core)
            try testing.expectEqual(@as(usize, 2), metric.data_points.len);
        }
    }
    try testing.expect(found_counter);
}
