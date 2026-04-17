//! Tests for Async Instruments Thread Safety
//!
//! This module tests the thread safety of observable instruments, including
//! concurrent callback registration, concurrent collection, and race conditions.

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

fn nanoTimestamp() i64 {
    var ts: std.posix.system.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

const ObservableResult = otel_api.metrics.ObservableResult;
const TypeErasedCallback = otel_api.metrics.TypeErasedCallback;
const createTypeErasedCallback = otel_api.metrics.createTypeErasedCallback;
const AttributeKeyValue = otel_api.common.AttributeKeyValue;

const AsyncInstrumentConfig = otel_sdk.metrics.AsyncInstrumentConfig;
const SdkObservableCounter = otel_sdk.metrics.SdkObservableCounter;
const SdkObservableGauge = otel_sdk.metrics.SdkObservableGauge;

// Thread-safe test state
const ThreadSafeState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    counter: u32 = 0,
    thread_id: std.atomic.Value(u32) = .init(0),
    operations: std.atomic.Value(u32) = .init(0),
    errors: std.atomic.Value(u32) = .init(0),

    fn incrementCounter(self: *ThreadSafeState) u32 {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.counter += 1;
        return self.counter;
    }

    fn recordOperation(self: *ThreadSafeState, thread_id: u32) void {
        _ = self.operations.fetchAdd(1, .monotonic);
        self.thread_id.store(thread_id, .monotonic);
    }

    fn recordError(self: *ThreadSafeState) void {
        _ = self.errors.fetchAdd(1, .monotonic);
    }

    fn getOperations(self: *ThreadSafeState) u32 {
        return self.operations.load(.monotonic);
    }

    fn getErrors(self: *ThreadSafeState) u32 {
        return self.errors.load(.monotonic);
    }
};

// Callback that records thread safety information
fn threadSafeCallback(result: *ObservableResult(i64), state: *ThreadSafeState) void {
    const thread_id = std.Thread.getCurrentId();
    state.recordOperation(@intCast(thread_id));

    const value = state.incrementCounter();
    const attrs = [_]AttributeKeyValue{
        .{ .key = "thread_id", .value = .{ .int = @intCast(thread_id) } },
        .{ .key = "operation", .value = .{ .int = @intCast(value) } },
    };

    result.observe(@intCast(value), &attrs, null) catch {
        state.recordError();
    };
}

// Heavy callback that does work while holding locks
fn heavyThreadSafeCallback(result: *ObservableResult(i64), state: *ThreadSafeState) void {
    const thread_id = std.Thread.getCurrentId();
    state.recordOperation(@intCast(thread_id));

    // Simulate some work
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};

    for (0..3) |i| {
        const value = state.incrementCounter();
        const attrs = [_]AttributeKeyValue{
            .{ .key = "thread_id", .value = .{ .int = @intCast(thread_id) } },
            .{ .key = "batch", .value = .{ .int = @intCast(i) } },
            .{ .key = "value", .value = .{ .int = @intCast(value) } },
        };

        result.observe(@intCast(value), &attrs, null) catch {
            state.recordError();
        };
    }
}

test "concurrent callback registration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.concurrent.registration",
        "Test concurrent registration",
        "count",
        AsyncInstrumentConfig.default(),
    );
    defer counter.deinit();

    const num_threads = 5;
    const callbacks_per_thread = 3;

    var threads: [num_threads]std.Thread = undefined;
    var states: [num_threads]ThreadSafeState = undefined;
    var handles: [num_threads * callbacks_per_thread]@TypeOf(counter.registerCallback(undefined)) = undefined;

    // Thread function that registers multiple callbacks
    const ThreadWork = struct {
        fn registerCallbacks(args: struct { counter_ptr: *SdkObservableCounter(i64), state_ptr: *ThreadSafeState, handles_start: []@TypeOf(counter.registerCallback(undefined)) }) void {
            for (0..callbacks_per_thread) |i| {
                const callback = createTypeErasedCallback(i64, ThreadSafeState, threadSafeCallback, args.state_ptr);
                args.handles_start[i] = args.counter_ptr.registerCallback(callback);

                // Small delay to increase chance of race conditions
                std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
            }
        }
    };

    // Initialize states
    for (0..num_threads) |i| {
        states[i] = ThreadSafeState{};
    }

    // Start threads that register callbacks concurrently
    for (0..num_threads) |i| {
        const args = .{
            .counter_ptr = &counter,
            .state_ptr = &states[i],
            .handles_start = handles[i * callbacks_per_thread .. (i + 1) * callbacks_per_thread],
        };
        threads[i] = try std.Thread.spawn(.{}, ThreadWork.registerCallbacks, .{args});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Test that all callbacks were registered successfully
    const metrics = try counter.collect(allocator);
    defer allocator.free(metrics);

    // Should have measurements from all registered callbacks
    try testing.expectEqual(@as(usize, num_threads * callbacks_per_thread), metrics.len);

    // Clean up handles
    for (handles) |handle| {
        handle.unregister();
    }

    // Verify no measurements after unregistration
    const empty_metrics = try counter.collect(allocator);
    defer allocator.free(empty_metrics);
    try testing.expectEqual(@as(usize, 0), empty_metrics.len);
}

test "concurrent collection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gauge = SdkObservableGauge(i64).init(
        allocator,
        "test.concurrent.collection",
        "Test concurrent collection",
        "units",
        AsyncInstrumentConfig{
            .track_callback_metrics = true,
            .error_policy = .log_continue,
        },
    );
    defer gauge.deinit();

    // Register some callbacks
    var state1 = ThreadSafeState{};
    var state2 = ThreadSafeState{};

    const callback1 = createTypeErasedCallback(i64, ThreadSafeState, threadSafeCallback, &state1);
    const callback2 = createTypeErasedCallback(i64, ThreadSafeState, heavyThreadSafeCallback, &state2);

    const handle1 = gauge.registerCallback(callback1);
    const handle2 = gauge.registerCallback(callback2);

    defer {
        handle1.unregister();
        handle2.unregister();
    }

    const num_threads = 4;
    const collections_per_thread = 5;
    var threads: [num_threads]std.Thread = undefined;
    var results: [num_threads][collections_per_thread]bool = undefined;

    // Thread function that performs collections
    const CollectionWork = struct {
        fn collectMetrics(args: struct {
            gauge_ptr: *SdkObservableGauge(i64),
            allocator_ptr: std.mem.Allocator,
            results_ptr: *[collections_per_thread]bool,
            thread_index: usize,
        }) void {
            for (0..collections_per_thread) |i| {
                const metrics = args.gauge_ptr.collect(args.allocator_ptr) catch {
                    args.results_ptr[i] = false;
                    continue;
                };
                defer args.allocator_ptr.free(metrics);

                // Verify we got some measurements
                args.results_ptr[i] = metrics.len > 0;

                // Small delay to increase thread interleaving
                std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
            }
        }
    };

    // Start threads that collect concurrently
    for (0..num_threads) |i| {
        results[i] = [_]bool{false} ** collections_per_thread;
        const args = .{
            .gauge_ptr = &gauge,
            .allocator_ptr = allocator,
            .results_ptr = &results[i],
            .thread_index = i,
        };
        threads[i] = try std.Thread.spawn(.{}, CollectionWork.collectMetrics, .{args});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Verify all collections succeeded
    var total_successful = 0;
    for (results) |thread_results| {
        for (thread_results) |success| {
            if (success) total_successful += 1;
        }
    }

    try testing.expect(total_successful >= num_threads * collections_per_thread / 2); // At least 50% success rate

    // Verify states were updated (callbacks were executed)
    try testing.expect(state1.getOperations() > 0);
    try testing.expect(state2.getOperations() > 0);

    // Check callback metrics
    const instrument_metrics = gauge.getInstrumentMetrics();
    try testing.expect(instrument_metrics.total_executions > 0);
}

test "race conditions during registration and collection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.race.conditions",
        "Test race conditions",
        "count",
        AsyncInstrumentConfig.default(),
    );
    defer counter.deinit();

    var shared_state = ThreadSafeState{};
    const num_threads = 6;
    var threads: [num_threads]std.Thread = undefined;

    // Some threads register callbacks, others collect, others unregister
    const RaceWork = struct {
        fn raceWorker(args: struct {
            counter_ptr: *SdkObservableCounter(i64),
            state_ptr: *ThreadSafeState,
            allocator_ptr: std.mem.Allocator,
            thread_index: usize,
        }) void {
            const thread_id = args.thread_index;

            if (thread_id < 2) {
                // Registration threads
                for (0..3) |_| {
                    const callback = createTypeErasedCallback(i64, ThreadSafeState, threadSafeCallback, args.state_ptr);
                    const handle = args.counter_ptr.registerCallback(callback);

                    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
                    handle.unregister();
                    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
                }
            } else if (thread_id < 4) {
                // Collection threads
                for (0..5) |_| {
                    const metrics = args.counter_ptr.collect(args.allocator_ptr) catch continue;
                    defer args.allocator_ptr.free(metrics);

                    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
                }
            } else {
                // Mixed operation threads
                for (0..3) |i| {
                    if (i % 2 == 0) {
                        const callback = createTypeErasedCallback(i64, ThreadSafeState, threadSafeCallback, args.state_ptr);
                        const handle = args.counter_ptr.registerCallback(callback);
                        defer handle.unregister();

                        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
                    } else {
                        const metrics = args.counter_ptr.collect(args.allocator_ptr) catch continue;
                        defer args.allocator_ptr.free(metrics);
                    }
                }
            }
        }
    };

    // Start all threads
    for (0..num_threads) |i| {
        const args = .{
            .counter_ptr = &counter,
            .state_ptr = &shared_state,
            .allocator_ptr = allocator,
            .thread_index = i,
        };
        threads[i] = try std.Thread.spawn(.{}, RaceWork.raceWorker, .{args});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Test that the system survived the race conditions
    // Should be able to collect without crashing
    const final_metrics = try counter.collect(allocator);
    defer allocator.free(final_metrics);

    // The exact number of metrics depends on timing, but it should not crash
    try testing.expect(shared_state.getOperations() > 0);

    std.log.info("Race conditions test completed with {} operations and {} errors", .{ shared_state.getOperations(), shared_state.getErrors() });
}

test "thread safety of callback metrics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gauge = SdkObservableGauge(i64).init(
        allocator,
        "test.metrics.thread.safety",
        "Test metrics thread safety",
        "units",
        AsyncInstrumentConfig{
            .track_callback_metrics = true,
        },
    );
    defer gauge.deinit();

    var state = ThreadSafeState{};
    const callback = createTypeErasedCallback(i64, ThreadSafeState, heavyThreadSafeCallback, &state);
    const handle = gauge.registerCallback(callback);
    defer handle.unregister();

    const num_threads = 3;
    var threads: [num_threads]std.Thread = undefined;

    // Thread function that accesses callback metrics while collections happen
    const MetricsWork = struct {
        fn accessMetrics(args: struct {
            gauge_ptr: *SdkObservableGauge(i64),
            allocator_ptr: std.mem.Allocator,
        }) void {
            for (0..10) |_| {
                // Collect metrics
                const metrics = args.gauge_ptr.collect(args.allocator_ptr) catch continue;
                defer args.allocator_ptr.free(metrics);

                // Access callback metrics concurrently
                const instrument_metrics = args.gauge_ptr.getInstrumentMetrics();
                _ = instrument_metrics.total_executions;

                const all_callback_metrics = args.gauge_ptr.getAllCallbackMetrics(args.allocator_ptr) catch continue;
                defer args.allocator_ptr.free(all_callback_metrics);

                std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
            }
        }
    };

    // Start threads that access metrics concurrently
    for (0..num_threads) |i| {
        const args = .{
            .gauge_ptr = &gauge,
            .allocator_ptr = allocator,
        };
        threads[i] = try std.Thread.spawn(.{}, MetricsWork.accessMetrics, .{args});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Verify final state is consistent
    const final_metrics = gauge.getInstrumentMetrics();
    try testing.expect(final_metrics.total_executions >= num_threads * 10);
    try testing.expect(final_metrics.total_execution_time_ns > 0);
}

test "stress test with many concurrent operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var counter = SdkObservableCounter(i64).init(
        allocator,
        "test.stress",
        "Test stress",
        "count",
        AsyncInstrumentConfig{
            .track_callback_metrics = true,
            .max_measurements_per_callback = 10,
        },
    );
    defer counter.deinit();

    var shared_state = ThreadSafeState{};
    const num_worker_threads = 8;
    const operations_per_thread = 20;

    var threads: [num_worker_threads]std.Thread = undefined;
    var handles = std.ArrayList(@TypeOf(counter.registerCallback(undefined))).init(allocator);
    defer {
        for (handles.items) |handle| {
            handle.unregister();
        }
        handles.deinit();
    }

    // Pre-register some callbacks to start with
    for (0..3) |_| {
        const callback = createTypeErasedCallback(i64, ThreadSafeState, threadSafeCallback, &shared_state);
        try handles.append(counter.registerCallback(callback));
    }

    // Thread function that performs many operations
    const StressWork = struct {
        fn stressWorker(args: struct {
            counter_ptr: *SdkObservableCounter(i64),
            state_ptr: *ThreadSafeState,
            allocator_ptr: std.mem.Allocator,
            handles_ptr: *std.ArrayList(@TypeOf(counter.registerCallback(undefined))),
            thread_index: usize,
        }) void {
            var local_handles = std.ArrayList(@TypeOf(counter.registerCallback(undefined))).init(args.allocator_ptr);
            defer {
                for (local_handles.items) |handle| {
                    handle.unregister();
                }
                local_handles.deinit();
            }

            for (0..operations_per_thread) |op| {
                switch (op % 4) {
                    0 => {
                        // Register callback
                        const callback = createTypeErasedCallback(i64, ThreadSafeState, threadSafeCallback, args.state_ptr);
                        local_handles.append(args.counter_ptr.registerCallback(callback)) catch {};
                    },
                    1 => {
                        // Collect metrics
                        const metrics = args.counter_ptr.collect(args.allocator_ptr) catch continue;
                        defer args.allocator_ptr.free(metrics);
                    },
                    2 => {
                        // Unregister a callback if we have any
                        if (local_handles.items.len > 0) {
                            const handle = local_handles.pop();
                            handle.unregister();
                        }
                    },
                    3 => {
                        // Access metrics
                        const instrument_metrics = args.counter_ptr.getInstrumentMetrics();
                        _ = instrument_metrics.total_executions;
                    },
                    else => unreachable,
                }

                // Small delay to increase concurrency
                if (op % 5 == 0) {
                    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(\1), .awake) catch {};
                }
            }
        }
    };

    const start_time = nanoTimestamp();

    // Start stress test threads
    for (0..num_worker_threads) |i| {
        const args = .{
            .counter_ptr = &counter,
            .state_ptr = &shared_state,
            .allocator_ptr = allocator,
            .handles_ptr = &handles,
            .thread_index = i,
        };
        threads[i] = try std.Thread.spawn(.{}, StressWork.stressWorker, .{args});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    const end_time = nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Final verification
    const final_metrics = try counter.collect(allocator);
    defer allocator.free(final_metrics);

    const instrument_metrics = counter.getInstrumentMetrics();

    try testing.expect(shared_state.getOperations() > 0);
    try testing.expect(instrument_metrics.total_executions > 0);

    std.log.info("Stress test completed in {d:.2}ms:", .{duration_ms});
    std.log.info("  Operations: {}", .{shared_state.getOperations()});
    std.log.info("  Errors: {}", .{shared_state.getErrors()});
    std.log.info("  Callback executions: {}", .{instrument_metrics.total_executions});
    std.log.info("  Final measurements: {}", .{final_metrics.len});

    // Should complete in reasonable time (stress test, so allow more time)
    try testing.expect(duration_ms < 5000.0); // 5 seconds max
}
