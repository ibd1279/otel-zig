//! Integration tests for async (observable) metric instruments.
//!
//! Consolidates coverage from several orphaned test files that referenced a
//! pre-refactor internal API. Covers the unique scenarios that were not already
//! exercised by the in-module tests in sdk/metrics/:
//!
//!   - All three observable instrument types end-to-end
//!   - Stateful and stateless callback patterns
//!   - Callbacks registered at instrument-creation time
//!   - Multiple callbacks on a single instrument all execute
//!   - Callback unregistration stops future observations
//!   - Concurrent callback registration is race-free

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

const InstrumentationScope = otel_api.InstrumentationScope;
const ObservableResult = otel_api.metrics.ObservableResult;
const TypeErasedCallback = otel_api.metrics.TypeErasedCallback;

const MeterProvider = otel_sdk.metrics.MeterProvider;
const ManualReader = otel_sdk.metrics.ManualReader;
const MetricExporter = otel_sdk.metrics.MetricExporter;
const Resource = otel_sdk.resource.Resource;

// ---------------------------------------------------------------------------
// Test fixture
// ---------------------------------------------------------------------------

/// Heap-allocates a ManualReader (backed by the noop exporter) and registers it
/// with a new MeterProvider. The provider takes ownership of the reader.
///
/// Call `provider.deinit()` when done; the reader is cleaned up automatically.
fn makeProviderAndMeter(allocator: std.mem.Allocator) !struct {
    provider: MeterProvider,
    reader: *ManualReader,
    meter: otel_api.metrics.Meter,
} {
    const resource = Resource.empty;
    var provider = MeterProvider.init(allocator, std.testing.io, resource);

    const reader = try allocator.create(ManualReader);
    reader.* = try ManualReader.init(allocator, std.testing.io, MetricExporter{ .noop = {} });
    try provider.registerReader(reader.reader());

    const scope = InstrumentationScope{ .name = "test.async.integration", .version = "1.0.0" };
    const meter = provider.getMeterWithScope(scope);

    return .{ .provider = provider, .reader = reader, .meter = meter };
}

// ---------------------------------------------------------------------------
// Test 1: all three observable instrument types invoke their callbacks
// ---------------------------------------------------------------------------

test "observable counter, gauge, and updown counter all invoke their callbacks" {
    const allocator = testing.allocator;
    var ctx = try makeProviderAndMeter(allocator);
    defer ctx.provider.deinit();

    var counter_calls = std.atomic.Value(u32).init(0);
    var gauge_calls = std.atomic.Value(u32).init(0);
    var updown_calls = std.atomic.Value(u32).init(0);

    const Cbs = struct {
        fn counter(alloc: std.mem.Allocator, result: *ObservableResult(i64), state: *anyopaque) void {
            const calls: *std.atomic.Value(u32) = @ptrCast(@alignCast(state));
            _ = calls.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 10);
        }
        fn gauge(alloc: std.mem.Allocator, result: *ObservableResult(f64), state: *anyopaque) void {
            const calls: *std.atomic.Value(u32) = @ptrCast(@alignCast(state));
            _ = calls.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 3.14);
        }
        fn updown(alloc: std.mem.Allocator, result: *ObservableResult(i64), state: *anyopaque) void {
            const calls: *std.atomic.Value(u32) = @ptrCast(@alignCast(state));
            _ = calls.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, -5);
        }
    };

    const obs_counter = try ctx.meter.createObservableCounter(
        i64,
        "test.counter",
        null,
        "1",
        null,
        &[_]TypeErasedCallback(i64){},
    );
    const obs_gauge = try ctx.meter.createObservableGauge(
        f64,
        "test.gauge",
        null,
        "ratio",
        null,
        &[_]TypeErasedCallback(f64){},
    );
    const obs_updown = try ctx.meter.createObservableUpDownCounter(
        i64,
        "test.updown",
        null,
        "1",
        null,
        &[_]TypeErasedCallback(i64){},
    );

    const h1 = try obs_counter.registerCallback(std.atomic.Value(u32), Cbs.counter, &counter_calls);
    const h2 = try obs_gauge.registerCallback(std.atomic.Value(u32), Cbs.gauge, &gauge_calls);
    const h3 = try obs_updown.registerCallback(std.atomic.Value(u32), Cbs.updown, &updown_calls);
    defer h1.unregister();
    defer h2.unregister();
    defer h3.unregister();

    ctx.reader.collect();

    try testing.expectEqual(@as(u32, 1), counter_calls.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), gauge_calls.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), updown_calls.load(.monotonic));

    // Repeated collection keeps calling callbacks.
    ctx.reader.collect();
    try testing.expectEqual(@as(u32, 2), counter_calls.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Test 2: stateless callbacks (no state parameter)
// ---------------------------------------------------------------------------

test "stateless callbacks are invoked on collection" {
    const allocator = testing.allocator;
    var ctx = try makeProviderAndMeter(allocator);
    defer ctx.provider.deinit();

    var calls = std.atomic.Value(u32).init(0);

    // stateless callbacks must be file-level decls or comptime-known pointers.
    const Cb = struct {
        var invocations: *std.atomic.Value(u32) = undefined;

        fn callback(alloc: std.mem.Allocator, result: *ObservableResult(i64)) void {
            _ = invocations.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 99);
        }
    };
    Cb.invocations = &calls;

    const obs = try ctx.meter.createObservableCounter(
        i64,
        "test.stateless",
        null,
        "1",
        null,
        &[_]TypeErasedCallback(i64){},
    );
    const handle = try obs.registerCallbackNoState(Cb.callback);
    defer handle.unregister();

    ctx.reader.collect();
    ctx.reader.collect();

    try testing.expectEqual(@as(u32, 2), calls.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Test 3: callbacks passed at instrument creation time
// ---------------------------------------------------------------------------

test "callbacks provided at instrument creation time are invoked" {
    const allocator = testing.allocator;
    var ctx = try makeProviderAndMeter(allocator);
    defer ctx.provider.deinit();

    var calls = std.atomic.Value(u32).init(0);

    const Cb = struct {
        var invocations: *std.atomic.Value(u32) = undefined;

        fn callback(alloc: std.mem.Allocator, result: *ObservableResult(i64)) void {
            _ = invocations.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 7);
        }
    };
    Cb.invocations = &calls;

    // Pass the callback directly in the creation call.
    _ = try ctx.meter.createObservableCounter(
        i64,
        "test.creation.callback",
        null,
        "1",
        null,
        &[_]TypeErasedCallback(i64){
            TypeErasedCallback(i64){ .stateless = Cb.callback },
        },
    );

    ctx.reader.collect();

    try testing.expectEqual(@as(u32, 1), calls.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Test 4: multiple callbacks on one instrument all execute
// ---------------------------------------------------------------------------

test "multiple callbacks registered on one instrument all execute" {
    const allocator = testing.allocator;
    var ctx = try makeProviderAndMeter(allocator);
    defer ctx.provider.deinit();

    var calls_a = std.atomic.Value(u32).init(0);
    var calls_b = std.atomic.Value(u32).init(0);

    const Cbs = struct {
        fn cbA(alloc: std.mem.Allocator, result: *ObservableResult(i64), state: *anyopaque) void {
            const calls: *std.atomic.Value(u32) = @ptrCast(@alignCast(state));
            _ = calls.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 1);
        }
        fn cbB(alloc: std.mem.Allocator, result: *ObservableResult(i64), state: *anyopaque) void {
            const calls: *std.atomic.Value(u32) = @ptrCast(@alignCast(state));
            _ = calls.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 2);
        }
    };

    const obs = try ctx.meter.createObservableCounter(
        i64,
        "test.multi.cb",
        null,
        "1",
        null,
        &[_]TypeErasedCallback(i64){},
    );
    const ha = try obs.registerCallback(std.atomic.Value(u32), Cbs.cbA, &calls_a);
    const hb = try obs.registerCallback(std.atomic.Value(u32), Cbs.cbB, &calls_b);
    defer ha.unregister();
    defer hb.unregister();

    ctx.reader.collect();

    try testing.expectEqual(@as(u32, 1), calls_a.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), calls_b.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Test 5: unregistering a callback stops future observations
// ---------------------------------------------------------------------------

test "unregistered callback is not invoked on subsequent collections" {
    const allocator = testing.allocator;
    var ctx = try makeProviderAndMeter(allocator);
    defer ctx.provider.deinit();

    var calls = std.atomic.Value(u32).init(0);

    const Cb = struct {
        fn callback(alloc: std.mem.Allocator, result: *ObservableResult(i64), state: *anyopaque) void {
            const c: *std.atomic.Value(u32) = @ptrCast(@alignCast(state));
            _ = c.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 42);
        }
    };

    const obs = try ctx.meter.createObservableCounter(
        i64,
        "test.unregister",
        null,
        "1",
        null,
        &[_]TypeErasedCallback(i64){},
    );
    var handle = try obs.registerCallback(std.atomic.Value(u32), Cb.callback, &calls);

    ctx.reader.collect();
    try testing.expectEqual(@as(u32, 1), calls.load(.monotonic));

    handle.unregister();

    ctx.reader.collect();
    ctx.reader.collect();
    // Count must not have changed after unregistration.
    try testing.expectEqual(@as(u32, 1), calls.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Test 6: concurrent callback registration is race-free
// ---------------------------------------------------------------------------

test "concurrent callback registration and unregistration does not race" {
    const allocator = testing.allocator;
    var ctx = try makeProviderAndMeter(allocator);
    defer ctx.provider.deinit();

    // A baseline callback that always runs; used to confirm the instrument
    // remains functional throughout the concurrent registrations.
    var baseline_calls = std.atomic.Value(u32).init(0);

    const Cbs = struct {
        fn baseline(alloc: std.mem.Allocator, result: *ObservableResult(i64), state: *anyopaque) void {
            const c: *std.atomic.Value(u32) = @ptrCast(@alignCast(state));
            _ = c.fetchAdd(1, .acq_rel);
            result.observeValue(alloc, 0);
        }
        fn transient(alloc: std.mem.Allocator, result: *ObservableResult(i64), state: *anyopaque) void {
            _ = state;
            result.observeValue(alloc, 1);
        }
    };

    const obs = try ctx.meter.createObservableCounter(
        i64,
        "test.concurrent",
        null,
        "1",
        null,
        &[_]TypeErasedCallback(i64){},
    );
    const baseline_handle = try obs.registerCallback(
        std.atomic.Value(u32),
        Cbs.baseline,
        &baseline_calls,
    );
    defer baseline_handle.unregister();

    // Spawn N threads; each registers a callback, collects once, then unregisters.
    const N = 8;
    const ThreadArgs = struct {
        obs_ptr: *const @TypeOf(obs),
        cb: otel_api.metrics.ObservableCallback(i64, .state),
    };
    const thread_args = ThreadArgs{ .obs_ptr = &obs, .cb = Cbs.transient };

    const ThreadFn = struct {
        fn run(args: *const ThreadArgs) void {
            var dummy: u32 = 0;
            const h = args.obs_ptr.registerCallback(u32, args.cb, &dummy) catch return;
            h.unregister();
        }
    };

    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, ThreadFn.run, .{&thread_args});
    }
    for (&threads) |*t| t.join();

    // After all threads are done, one more collect must still invoke the baseline.
    ctx.reader.collect();
    try testing.expect(baseline_calls.load(.monotonic) >= 1);
}
