//! Basic Aggregation Types for OpenTelemetry Metrics SDK
//!
//! This module provides the basic aggregation implementations used by the metrics SDK.
//! These aggregations handle the collection and computation of metric data points.

const std = @import("std");

const InstrumentType = @import("metadata.zig").InstrumentType;

/// Aggregation union type that supports all aggregation variants
pub const Aggregation = union(enum) {
    sum_i64: SumAggregation(i64),
    sum_f64: SumAggregation(f64),
    last_value_i64: LastValueAggregation(i64),
    last_value_f64: LastValueAggregation(f64),
    histogram_i64: HistogramAggregation(i64),
    histogram_f64: HistogramAggregation(f64),
    drop: void, // Drop aggregation - ignores all measurements

    // Add a measurement to this aggregation (lock-free)
    pub fn add(self: *Aggregation, value: anytype) void {
        const T = @TypeOf(value);
        switch (self.*) {
            .sum_i64 => |*s| if (T == i64) s.add(value) else unreachable,
            .sum_f64 => |*s| if (T == f64) s.add(value) else unreachable,
            else => unreachable,
        }
    }

    /// Record a measurement on this aggregation (lock-free)
    pub fn record(self: *Aggregation, value: anytype) bool {
        const T = @TypeOf(value);
        switch (self.*) {
            .sum_i64 => |*s| if (T == i64) return s.record(value, false) else unreachable,
            .sum_f64 => |*s| if (T == f64) return s.record(value, false) else unreachable,
            .last_value_i64 => |*lv| if (T == i64) lv.record(value) else unreachable,
            .last_value_f64 => |*lv| if (T == f64) lv.record(value) else unreachable,
            .histogram_i64 => |*h| if (T == i64) h.record(value) else unreachable,
            .histogram_f64 => |*h| if (T == f64) h.record(value) else unreachable,
            .drop => {}, // Intentionally do nothing
        }
        return true;
    }

    pub fn reset(self: *Aggregation, io: std.Io) void {
        switch (self.*) {
            .sum_i64 => |*s| s.reset(io),
            .sum_f64 => |*s| s.reset(io),
            .last_value_i64 => |*s| s.reset(),
            .last_value_f64 => |*s| s.reset(),
            .histogram_i64 => |*s| s.reset(io),
            .histogram_f64 => |*s| s.reset(io),
            .drop => {},
        }
    }

    /// Clean up aggregation resources
    pub fn deinit(self: *Aggregation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .histogram_i64 => |*h| h.deinit(allocator),
            .histogram_f64 => |*h| h.deinit(allocator),
            else => {}, // Other aggregations don't need cleanup
        }
    }
};

/// Aggregation state for sum aggregation
pub fn SumAggregation(comptime T: type) type {
    return struct {
        value: std.atomic.Value(T) = .init(0),
        start_timestamp: std.Io.Timestamp,

        pub fn init() @This() {
            return .{
                .value = .init(0),
                .start_timestamp = std.Io.Timestamp.zero,
            };
        }

        pub fn add(self: *@This(), value: T) void {
            _ = self.value.fetchAdd(value, .monotonic);
        }

        /// Attempt to replace the aggregation value.
        ///
        /// If monotonic is true, the new value must be higher than the old value.
        /// returns true on successfully recording the value. false otherwise.
        pub fn record(self: *@This(), value: T, monotonic: bool) bool {
            return if (monotonic and T != f64) blk: {
                var old_value = value;
                while (self.value.cmpxchgWeak(old_value, value, .release, .acquire)) |v| {
                    if (v > value) break :blk false;
                    old_value = v;
                }
                break :blk true;
            } else if (monotonic and T == f64) blk: {
                const v = self.value.load(.acquire);
                if (v > value) break :blk false;
                self.value.store(value, .release);
                break :blk false;
            } else blk: {
                self.value.store(value, .release);
                break :blk true;
            };
        }

        pub fn getValue(self: *const @This()) T {
            return self.value.load(.monotonic);
        }

        pub fn getStartTime(self: *const @This()) std.Io.Timestamp {
            return self.start_timestamp;
        }

        pub fn reset(self: *@This(), io: std.Io) void {
            self.value.store(0, .monotonic);
            self.start_timestamp = std.Io.Clock.real.now(io);
        }
    };
}

/// Aggregation state for last value aggregation
pub fn LastValueAggregation(comptime T: type) type {
    return struct {
        // zig doesn't support `?(i64|f64)` with atomic.
        // zig only supports powers of 2 for the bit length with atomic.
        /// the 65th bit is the optional flag; 0 == null; 1 == value
        value: std.atomic.Value(u128) = .init(0),

        pub fn init() @This() {
            return .{
                .value = .init(0),
            };
        }

        pub fn record(self: *@This(), value: T) void {
            const bits: u64 = @bitCast(value);
            const guarded: u128 = @as(u128, bits) | (1 << 64);
            self.value.store(guarded, .monotonic);
        }

        pub fn getValue(self: *const @This()) ?T {
            const guarded = self.value.load(.monotonic);
            return if (guarded & (1 << 64) == 0)
                null
            else
                @bitCast(@as(u64, @truncate(guarded)));
        }

        pub fn reset(self: *@This()) void {
            self.value.store(0, .monotonic);
        }
    };
}

/// Histogram aggregation state
pub fn HistogramAggregation(comptime T: type) type {
    return struct {
        boundaries: []const f64,
        counts: []std.atomic.Value(u64),
        sum: std.atomic.Value(T) = .init(0),
        count: std.atomic.Value(u64) = .init(0),
        start_timestamp: std.Io.Timestamp,
        record_min_max: bool,

        // similar to LastValueAggregation, no support of optionals.
        min: std.atomic.Value(u128) = .init(0),
        max: std.atomic.Value(u128) = .init(0),

        pub fn init(allocator: std.mem.Allocator, config: HistogramAggregationConfig) !@This() {
            const counts = try allocator.alloc(std.atomic.Value(u64), config.boundaries.len + 1);
            for (counts) |*count| {
                count.* = std.atomic.Value(u64).init(0);
            }

            return .{
                .boundaries = config.boundaries,
                .counts = counts,
                .start_timestamp = std.Io.Timestamp.zero,
                .record_min_max = config.record_min_max,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.counts);
        }

        pub fn record(self: *@This(), value: T) void {
            // Atomic operations for sum and count
            _ = self.count.fetchAdd(1, .monotonic);
            _ = self.sum.fetchAdd(value, .monotonic);

            if (self.record_min_max) {
                // Simple atomic min/max
                const bits: u64 = @bitCast(value);
                const value_guarded: u128 = @as(u128, bits) | (1 << 64);

                // min will always be "decreasing", even if it changes
                var expected_guarded = value_guarded;
                while (self.min.cmpxchgWeak(expected_guarded, value_guarded, .acq_rel, .monotonic)) |new_expected| {
                    if (new_expected & (1 << 64) == 0) {
                        // new_expected was null, so retry to set the first value
                        expected_guarded = new_expected;
                    } else {
                        // new_expected is a value, so we have to compare before we can try again.
                        const expected: T = @bitCast(@as(u64, @truncate(new_expected)));
                        if (value >= expected) break; // Min is already lower than our value.
                        expected_guarded = new_expected;
                    }
                }

                expected_guarded = value_guarded;
                while (self.max.cmpxchgWeak(expected_guarded, value_guarded, .acq_rel, .monotonic)) |new_expected| {
                    if (new_expected & (1 << 64) == 0) {
                        // new_expected was null, so retry to set the first value
                        expected_guarded = new_expected;
                    } else {
                        // new_expected is a value, so we have to compare before we can try again.
                        const expected: T = @bitCast(@as(u64, @truncate(new_expected)));
                        if (value <= expected) break; // Max is already higher than our value.
                        expected_guarded = new_expected;
                    }
                }
            }

            const bucket_index = self.findBucketIndex(value);
            _ = self.counts[bucket_index].fetchAdd(1, .monotonic);
        }

        pub fn findBucketIndex(self: *const @This(), value: T) usize {
            // For a given list of N boundaries [b_0, b_1, ..., b_{N-1}],
            // N+1 buckets are created. Each boundary value represents the inclusive
            // upper bound of a bucket.
            //
            // The resulting buckets are:
            //   - bucket[0]: (-inf, b_0]
            //   - bucket[1]: (b_0, b_1]
            //   - ...
            //   - bucket[N]: (b_{N-1}, +inf)
            //
            // This is why we allocate `boundaries.len + 1` space for the `counts` slice,
            // to accommodate the extra bucket for values greater than the last boundary.

            const float_value = switch (T) {
                i64 => @as(f64, @floatFromInt(value)),
                f64 => value,
                else => unreachable,
            };

            var left: usize = 0;
            var right: usize = self.boundaries.len;

            while (left < right) {
                const mid = left + (right - left) / 2;
                if (float_value <= self.boundaries[mid]) {
                    right = mid;
                } else {
                    left = mid + 1;
                }
            }

            return left;
        }

        pub fn getSum(self: *const @This()) T {
            return self.sum.load(.monotonic);
        }

        pub fn getCount(self: *const @This()) u64 {
            return self.count.load(.monotonic);
        }

        pub fn getMin(self: *const @This()) ?T {
            const guarded = self.min.load(.monotonic);
            return if (guarded & (1 << 64) == 0)
                null
            else
                @bitCast(@as(u64, @truncate(guarded)));
        }

        pub fn getMax(self: *const @This()) ?T {
            const guarded = self.max.load(.monotonic);
            return if (guarded & (1 << 64) == 0)
                null
            else
                @bitCast(@as(u64, @truncate(guarded)));
        }

        pub fn getBoundaries(self: *const @This()) []const f64 {
            return self.boundaries;
        }

        pub fn getCounts(self: *const @This()) []const std.atomic.Value(u64) {
            return self.counts;
        }

        pub fn getStartTime(self: *const @This()) std.Io.Timestamp {
            return self.start_timestamp;
        }

        pub fn reset(self: *@This(), io: std.Io) void {
            for (self.counts) |*count| {
                count.store(0, .monotonic);
            }
            self.sum.store(0, .monotonic);
            self.count.store(0, .monotonic);
            self.min.store(0, .monotonic);
            self.max.store(0, .monotonic);
            self.start_timestamp = std.Io.Clock.real.now(io);
        }
    };
}

pub const DEFAULT_HISTOGRAM_BOUNDARIES = [_]f64{
    0.0,   5.0,   10.0,   25.0,   50.0,   75.0,   100.0,   250.0,
    500.0, 750.0, 1000.0, 2500.0, 5000.0, 7500.0, 10000.0,
};

/// Configuration for histogram aggregation
pub const HistogramAggregationConfig = struct {
    boundaries: []const f64 = &DEFAULT_HISTOGRAM_BOUNDARIES,
    record_min_max: bool = true,
};

/// Aggregation temporality for metric data points
pub const AggregationTemporality = enum {
    delta,
    cumulative,
};

/// Types of aggregations available
pub const AggregationType = enum {
    sum,
    last_value,
    histogram,
    drop, // Special case: don't aggregate at all
};

const testing = @import("std").testing;

test "SumAggregation" {
    const io = std.testing.io;

    var sum = SumAggregation(i64).init();

    sum.add(10);
    sum.add(20);
    try testing.expectEqual(sum.getValue(), 30);
    try testing.expectEqual(sum.getStartTime(), sum.start_timestamp);
    const old_ts = sum.getStartTime();

    // Sleep briefly to ensure timestamp advances
    try std.Io.sleep(io, .{ .nanoseconds = 1000 }, .awake);

    sum.reset(io);
    try testing.expectEqual(sum.getValue(), 0);
    try testing.expect(sum.getStartTime().nanoseconds != old_ts.nanoseconds or old_ts.nanoseconds == 0);
}

test "LastValueAggregation" {
    var last_value = LastValueAggregation(i64).init();

    last_value.record(10);
    try testing.expectEqual(last_value.getValue(), 10);

    last_value.record(20);
    try testing.expectEqual(last_value.getValue(), 20);

    last_value.reset();
    try testing.expectEqual(last_value.getValue(), null);
}

test "HistogramAggregation findBucketIndex" {
    const allocator = std.heap.page_allocator;
    const config = HistogramAggregationConfig{};
    var histogram = try HistogramAggregation(i64).init(allocator, config);

    // Test cases for findBucketIndex
    const test_cases = [_]struct {
        value: i64,
        expected_index: usize,
    }{
        .{ .value = -1, .expected_index = 0 }, // Below the first boundary
        .{ .value = 0, .expected_index = 0 }, // Exactly on the first boundary
        .{ .value = 1, .expected_index = 1 }, // Just above the first boundary
        .{ .value = 4, .expected_index = 1 }, // Close to the first boundary
        .{ .value = 5, .expected_index = 1 }, // Exactly on the second boundary
        .{ .value = 6, .expected_index = 2 }, // Just above the second boundary
        .{ .value = 9, .expected_index = 2 }, // Close to the second boundary
        .{ .value = 10, .expected_index = 2 }, // Exactly on the third boundary
        .{ .value = 11, .expected_index = 3 }, // Just above the third boundary
        .{ .value = 24, .expected_index = 3 }, // Close to the third boundary
        .{ .value = 25, .expected_index = 3 }, // Exactly on the fourth boundary
        .{ .value = 26, .expected_index = 4 }, // Just above the fourth boundary
        .{ .value = 49, .expected_index = 4 }, // Close to the fourth boundary
        .{ .value = 50, .expected_index = 4 }, // Exactly on the fifth boundary
        .{ .value = 51, .expected_index = 5 }, // Just above the fifth boundary
        .{ .value = 74, .expected_index = 5 }, // Close to the fifth boundary
        .{ .value = 75, .expected_index = 5 }, // Exactly on the sixth boundary
        .{ .value = 76, .expected_index = 6 }, // Just above the sixth boundary
        .{ .value = 99, .expected_index = 6 }, // Close to the sixth boundary
        .{ .value = 100, .expected_index = 6 }, // Exactly on the seventh boundary
        .{ .value = 101, .expected_index = 7 }, // Just above the seventh boundary
        .{ .value = 249, .expected_index = 7 }, // Close to the seventh boundary
        .{ .value = 250, .expected_index = 7 }, // Exactly on the eighth boundary
        .{ .value = 251, .expected_index = 8 }, // Just above the eighth boundary
        .{ .value = 499, .expected_index = 8 }, // Close to the eighth boundary
        .{ .value = 500, .expected_index = 8 }, // Exactly on the ninth boundary
        .{ .value = 501, .expected_index = 9 }, // Just above the ninth boundary
        .{ .value = 749, .expected_index = 9 }, // Close to the ninth boundary
        .{ .value = 750, .expected_index = 9 }, // Exactly on the tenth boundary
        .{ .value = 751, .expected_index = 10 }, // Just above the tenth boundary
        .{ .value = 999, .expected_index = 10 }, // Close to the tenth boundary
        .{ .value = 1000, .expected_index = 10 }, // Exactly on the eleventh boundary
        .{ .value = 1001, .expected_index = 11 }, // Just above the eleventh boundary
        .{ .value = 2499, .expected_index = 11 }, // Close to the eleventh boundary
        .{ .value = 2500, .expected_index = 11 }, // Exactly on the twelfth boundary
        .{ .value = 2501, .expected_index = 12 }, // Just above the twelfth boundary
        .{ .value = 4999, .expected_index = 12 }, // Close to the twelfth boundary
        .{ .value = 5000, .expected_index = 12 }, // Exactly on the thirteenth boundary
        .{ .value = 5001, .expected_index = 13 }, // Just above the thirteenth boundary
        .{ .value = 7499, .expected_index = 13 }, // Close to the thirteenth boundary
        .{ .value = 7500, .expected_index = 13 }, // Exactly on the fourteenth boundary
        .{ .value = 7501, .expected_index = 14 }, // Just above the fourteenth boundary
        .{ .value = 9999, .expected_index = 14 }, // Close to the fourteenth boundary
        .{ .value = 10000, .expected_index = 14 }, // Exactly on the fifteenth boundary
        .{ .value = 10001, .expected_index = 15 }, // Just above the fifteenth boundary
        .{ .value = 100000, .expected_index = 15 }, // Clearly in the last bucket
    };

    for (test_cases) |test_case| {
        const index = histogram.findBucketIndex(test_case.value);
        testing.expectEqual(@as(usize, test_case.expected_index), index) catch |e| {
            std.log.err("test case for value {} failed.", .{test_case.value});
            return e;
        };
    }

    histogram.deinit(allocator);
}

test "HistogramAggregation" {
    const allocator = std.heap.page_allocator;
    const config = HistogramAggregationConfig{};
    var histogram = try HistogramAggregation(i64).init(allocator, config);

    histogram.record(10);
    histogram.record(20);
    try testing.expectEqual(histogram.getSum(), 30);
    try testing.expectEqual(histogram.getCount(), 2);
    try testing.expectEqual(histogram.getMin(), 10);
    try testing.expectEqual(histogram.getMax(), 20);

    const counts = histogram.getCounts();
    try testing.expectEqual(counts[0].load(.monotonic), 0);
    try testing.expectEqual(counts[1].load(.monotonic), 0);
    try testing.expectEqual(counts[2].load(.monotonic), 1);
    try testing.expectEqual(counts[3].load(.monotonic), 1);
    const old_ts = histogram.getStartTime();
    const io = std.testing.io;
    // Sleep briefly to ensure timestamp advances
    try std.Io.sleep(io, .{ .nanoseconds = 1000 }, .awake);

    histogram.reset(io);
    try testing.expectEqual(histogram.getSum(), 0);
    try testing.expectEqual(histogram.getCount(), 0);
    try testing.expectEqual(histogram.getMin(), null);
    try testing.expectEqual(histogram.getMax(), null);
    try testing.expect(histogram.getStartTime().nanoseconds != old_ts.nanoseconds or old_ts.nanoseconds == 0);

    histogram.deinit(allocator);
}
