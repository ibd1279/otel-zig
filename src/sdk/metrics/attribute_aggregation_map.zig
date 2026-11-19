//! Attribute Aggregation Map for OpenTelemetry Metrics SDK
//!
//! This module manages aggregations indexed by attribute combinations with
//! cardinality limits and overflow handling as per OpenTelemetry specification.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const InstrumentType = @import("metadata.zig").InstrumentType;
    const MetricValue = @import("reader.zig").MetricValue;
    const aggregations = @import("aggregations.zig");
    const computeAttributeHash = @import("metadata.zig").computeAttributeHash;
};

/// Entry that combines aggregation with its attributes for export
pub const AttributeAggregationEntry = struct {
    aggregation: Aggregation,
    attributes: []const api.AttributeKeyValue,
    metadata: sdk.MetricMetadata, // Complete metadata for export

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.aggregation.deinit(allocator);
        api.AttributeKeyValue.deinitOwnedSlice(allocator, self.attributes);
    }
};

/// Aggregation union type that supports all aggregation variants
pub const Aggregation = sdk.aggregations.Aggregation;
const AggregationTag = std.meta.Tag(Aggregation);

/// Attribute-based aggregation map with cardinality limits
pub const AttributeAggregationMap = struct {
    /// Default cardinality limit (matches the OpenTelemetry spec default of
    /// 2000 distinct (instrument, attribute-set) series per collection cycle).
    pub const DEFAULT_CARDINALITY_LIMIT: usize = 2000;

    /// Retained alias for callers that referenced the old fixed constant.
    pub const MAX_CARDINALITY: usize = DEFAULT_CARDINALITY_LIMIT;

    // Map from (instrument_hash + attribute_hash) to aggregation
    aggregations: std.AutoHashMap(u128, *AttributeAggregationEntry),

    // Pool of aggregation entries. Allocated at init() with the configured
    // cardinality limit, so the limit is a runtime choice and the memory cost
    // (sizeof(AttributeAggregationEntry) ~= 288 B per slot) scales with it.
    aggregation_pool: []AttributeAggregationEntry,
    overflow_aggregation: AttributeAggregationEntry,
    next_free: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    // Lock to prevent map corruption
    mutex: std.atomic.Mutex,

    /// Initialize the attribute aggregation map.
    ///
    /// `cardinality_limit` is the maximum number of distinct
    /// (instrument, attribute-set) series tracked per collection cycle.
    /// Measurements past the limit are DROPPED (see overflow_aggregation below).
    pub fn init(allocator: std.mem.Allocator, cardinality_limit: usize) !AttributeAggregationMap {
        const limit = @max(cardinality_limit, 1);
        const pool = try allocator.alloc(AttributeAggregationEntry, limit);
        errdefer allocator.free(pool);
        return .{
            .aggregations = std.AutoHashMap(u128, *AttributeAggregationEntry).init(allocator),
            .aggregation_pool = pool,
            .next_free = .init(0),
            .allocator = allocator,
            .overflow_aggregation = .{
                // Pre-allocated sentinel returned once the cardinality limit is
                // reached. It is a DROP aggregation: with a typed aggregation
                // here (the old .sum_i64), the first measurement of another
                // value type would have been recorded into it (corrupting the
                // series) or hit a type check. Dropping is the spec's behavior
                // for cardinality overflow.
                .aggregation = .{ .drop = {} },
                .attributes = try api.AttributeBuilder.init(allocator).finish(allocator), // This is owning for the aggregation
                .metadata = .{
                    // This is non-owning for the aggregation.
                    .name = "overflow",
                    .description = "Overflow aggregation",
                    .unit = "",
                    .instrument_type = .Counter,
                    .instrumentation_scope = api.InstrumentationScope{
                        .name = "otel.overflow",
                        .version = null,
                        .schema_url = null,
                        .attributes = &[_]api.AttributeKeyValue{},
                    },
                },
            },
            .mutex = .unlocked,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *AttributeAggregationMap) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        // Clean up aggregation entries that need allocator cleanup
        for (0..self.next_free.load(.monotonic)) |i| {
            self.aggregation_pool[i].deinit(self.allocator);
        }
        self.overflow_aggregation.deinit(self.allocator);
        self.aggregations.deinit();
        self.allocator.free(self.aggregation_pool);
    }

    /// Get or create aggregation for the given instrument and attribute combination
    pub fn getOrCreateAggregation(
        self: *AttributeAggregationMap,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
        value: sdk.MetricValue,
    ) *AttributeAggregationEntry {
        // Combine instrument metadata hash and attribute hash for unique key
        const attr_hash = sdk.computeAttributeHash(attributes, metadata_hash);
        // This key is overkill, but designed for future expansion.
        const combined_hash = (@as(u128, metadata_hash) << 64) | attr_hash;

        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        // Check if aggregation entry already exists
        if (self.aggregations.get(combined_hash)) |entry| {
            return entry;
        }

        // We're in a mutex, so this isn't critical to be atomic,
        // but leaving it atomic out of laziness.
        const next_free = self.next_free.load(.monotonic);

        // Check cardinality limit
        if (next_free >= self.aggregation_pool.len) {
            return &self.overflow_aggregation;
        }

        // Get next aggregation entry from pool
        const entry = &self.aggregation_pool[next_free];

        // Create owned attributes for this aggregation.
        const owned_attributes = api.AttributeKeyValue.initOwnedSlice(self.allocator, attributes) catch {
            // On error, return overflow
            return &self.overflow_aggregation;
        };

        // Initialize aggregation entry based on instrument type and value type
        entry.* = .{
            .aggregation = self.createAggregationForType(metadata, value) catch {
                // On error, return overflow
                return &self.overflow_aggregation;
            },
            .attributes = owned_attributes,
            .metadata = metadata,
        };

        // Store in map
        self.aggregations.put(combined_hash, entry) catch {
            // On error, clean up and return overflow
            entry.deinit(self.allocator);
            return &self.overflow_aggregation;
        };

        // we made it this far, which means we created a new aggregation.
        // advance the offset.
        _ = self.next_free.fetchAdd(1, .acq_rel);

        return entry;
    }

    /// Caller MUST hold `self.mutex` before calling this function.
    /// Identical to `getOrCreateAggregation` but assumes the lock is already held.
    pub fn getOrCreateAggregationLocked(
        self: *AttributeAggregationMap,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
        value: sdk.MetricValue,
    ) *AttributeAggregationEntry {
        const attr_hash = sdk.computeAttributeHash(attributes, metadata_hash);
        const combined_hash = (@as(u128, metadata_hash) << 64) | attr_hash;

        if (self.aggregations.get(combined_hash)) |entry| {
            return entry;
        }

        const next_free = self.next_free.load(.monotonic);

        if (next_free >= self.aggregation_pool.len) {
            return &self.overflow_aggregation;
        }

        const entry = &self.aggregation_pool[next_free];

        const owned_attributes = api.AttributeKeyValue.initOwnedSlice(self.allocator, attributes) catch {
            return &self.overflow_aggregation;
        };

        entry.* = .{
            .aggregation = self.createAggregationForType(metadata, value) catch {
                return &self.overflow_aggregation;
            },
            .attributes = owned_attributes,
            .metadata = metadata,
        };

        self.aggregations.put(combined_hash, entry) catch {
            entry.deinit(self.allocator);
            return &self.overflow_aggregation;
        };

        _ = self.next_free.fetchAdd(1, .acq_rel);

        return entry;
    }

    /// Create aggregation of the appropriate type for the instrument
    fn createAggregationForType(self: *AttributeAggregationMap, metadata: sdk.MetricMetadata, value: sdk.MetricValue) !Aggregation {
        return switch (metadata.instrument_type) {
            .Counter, .ObservableCounter => switch (value) {
                .i64 => .{ .sum_i64 = .init() },
                .f64 => .{ .sum_f64 = .init() },
            },
            .UpDownCounter, .ObservableUpDownCounter => switch (value) {
                .i64 => .{ .sum_i64 = .init() },
                .f64 => .{ .sum_f64 = .init() },
            },
            .Gauge, .ObservableGauge => switch (value) {
                .i64 => .{ .last_value_i64 = .init() },
                .f64 => .{ .last_value_f64 = .init() },
            },
            .Histogram => blk: {
                // Use advisory bucket boundaries if provided (Stable)
                // Non-owning reference - boundaries owned by instrument
                const config = sdk.aggregations.HistogramAggregationConfig{
                    .boundaries = metadata.histogram_boundaries orelse &sdk.aggregations.DEFAULT_HISTOGRAM_BOUNDARIES,
                    .record_min_max = true,
                };
                break :blk switch (value) {
                    .i64 => .{ .histogram_i64 = try .init(self.allocator, config) },
                    .f64 => .{ .histogram_f64 = try .init(self.allocator, config) },
                };
            },
        };
    }

    /// Configured cardinality limit for this map (series tracked per cycle).
    pub fn cardinalityLimit(self: *const AttributeAggregationMap) usize {
        return self.aggregation_pool.len;
    }

    /// Get current cardinality (number of unique attribute combinations)
    pub fn getCardinality(self: *const AttributeAggregationMap) usize {
        return self.next_free.load(.unordered);
    }

    /// Check if cardinality limit has been exceeded
    pub fn hasExceededLimit(self: *const AttributeAggregationMap) bool {
        return self.next_free.load(.monotonic) >= self.aggregation_pool.len;
    }

    /// Iterator for all aggregation entries
    pub fn iterator(self: *const AttributeAggregationMap) std.AutoHashMap(u128, *AttributeAggregationEntry).Iterator {
        return self.aggregations.iterator();
    }

    /// generate a snapshot of all the aggregations for collection
    pub fn snapshot(
        self: *AttributeAggregationMap,
        allocator: std.mem.Allocator,
        entry_list: *std.ArrayList(AttributeAggregationEntry),
        io: std.Io,
    ) !void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        // append the points to the snapshot.
        const next_free = self.next_free.load(.monotonic);
        try entry_list.ensureUnusedCapacity(allocator, next_free);

        // Reset the cardinality.
        for (self.aggregation_pool[0..next_free]) |*entry| {
            // In the current model, the collection is expected to use
            // an arena allocator. But that means we have to copy the
            // slices, since they are changing ownership and allocator,
            // and cannot use move semantics.
            var aggregation = entry.aggregation;
            switch (aggregation) {
                .histogram_i64 => |*hist| {
                    hist.counts = try allocator.dupe(std.atomic.Value(u64), hist.counts);
                    hist.boundaries = try allocator.dupe(f64, hist.boundaries);
                },
                .histogram_f64 => |*hist| {
                    hist.counts = try allocator.dupe(std.atomic.Value(u64), hist.counts);
                    hist.boundaries = try allocator.dupe(f64, hist.boundaries);
                },
                else => {},
            }
            try entry_list.append(allocator, .{
                .aggregation = aggregation,
                .attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, entry.attributes),
                .metadata = entry.metadata,
            });
            entry.deinit(self.allocator);
        }
        self.overflow_aggregation.aggregation.reset(io);
        self.next_free.store(0, .monotonic);
        self.aggregations.clearRetainingCapacity();
    }
};

test "AttributeAggregationMap - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = try AttributeAggregationMap.init(allocator, AttributeAggregationMap.DEFAULT_CARDINALITY_LIMIT);
    defer map.deinit();

    const metadata = sdk.MetricMetadata{
        .name = "test_counter",
        .description = "Test counter",
        .unit = "1",
        .instrument_type = .Counter,
        .instrumentation_scope = .{
            .name = "test_meter",
            .version = "1.0.0",
            .schema_url = "",
            .attributes = &[_]api.AttributeKeyValue{},
        },
    };

    const attributes = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "GET" } },
    };

    // Get aggregation for first time
    const entry1 = map.getOrCreateAggregation(&attributes, metadata, 12345, .{ .i64 = 42 });
    try testing.expect(@intFromPtr(entry1) != 0);
    try testing.expectEqual(@as(usize, 1), map.getCardinality());

    // Get same aggregation again
    const entry2 = map.getOrCreateAggregation(&attributes, metadata, 12345, .{ .i64 = 42 });
    try testing.expectEqual(entry1, entry2); // Should be same pointer

    // Different attributes should create new aggregation
    const attributes2 = [_]api.AttributeKeyValue{
        .{ .key = "method", .value = .{ .string = "POST" } },
    };
    const entry3 = map.getOrCreateAggregation(&attributes2, metadata, 12345, .{ .i64 = 42 });
    try testing.expect(entry3 != entry1);
    try testing.expectEqual(@as(usize, 2), map.getCardinality());
}

test "AttributeAggregationMap - runtime cardinality limit is honored" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // The limit is a runtime value: the pool is sized from it at init().
    var map = try AttributeAggregationMap.init(allocator, 3);
    defer map.deinit();

    try testing.expectEqual(@as(usize, 3), map.cardinalityLimit());
    try testing.expect(!map.hasExceededLimit());

    const metadata = sdk.MetricMetadata{
        .name = "test_counter",
        .description = "Test counter",
        .unit = "1",
        .instrument_type = .Counter,
        .instrumentation_scope = .{
            .name = "test_meter",
            .version = "1.0.0",
            .schema_url = "",
            .attributes = &[_]api.AttributeKeyValue{},
        },
    };

    // 4 distinct attribute sets against a limit of 3: the 4th lands in the
    // shared overflow entry and does NOT grow the cardinality.
    const values = [_][]const u8{ "a", "b", "c", "d" };
    for (values) |v| {
        const attributes = [_]api.AttributeKeyValue{
            .{ .key = "slot", .value = .{ .string = v } },
        };
        _ = map.getOrCreateAggregation(&attributes, metadata, 12345, .{ .i64 = 1 });
    }

    try testing.expectEqual(@as(usize, 3), map.getCardinality());
    try testing.expectEqual(@as(usize, 3), map.aggregation_pool.len);
    try testing.expect(map.hasExceededLimit());
}

test "AttributeAggregationMap - overflow drops either value type instead of aborting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Regression: the overflow entry used to be a typed .sum_i64 aggregation.
    // With a limit of 1, the second series (of any type) landed there, and a
    // measurement of the other value type hit `unreachable` in
    // Aggregation.record()/add() — a hard abort at host scale (AIA-60 crash
    // loop, 2026-11-19). Overflow must DROP, for both i64 and f64.
    var map = try AttributeAggregationMap.init(allocator, 1);
    defer map.deinit();

    const gauge_meta = sdk.MetricMetadata{
        .name = "test_gauge",
        .description = "Test gauge",
        .unit = "1",
        .instrument_type = .Gauge,
        .instrumentation_scope = .{
            .name = "test_meter",
            .version = "1.0.0",
            .schema_url = "",
            .attributes = &[_]api.AttributeKeyValue{},
        },
    };
    const counter_meta = sdk.MetricMetadata{
        .name = "test_counter",
        .description = "Test counter",
        .unit = "1",
        .instrument_type = .Counter,
        .instrumentation_scope = .{
            .name = "test_meter",
            .version = "1.0.0",
            .schema_url = "",
            .attributes = &[_]api.AttributeKeyValue{},
        },
    };

    const first = [_]api.AttributeKeyValue{
        .{ .key = "slot", .value = .{ .string = "a" } },
    };
    // Fill the single slot with an i64 series.
    _ = map.getOrCreateAggregation(&first, gauge_meta, 1, .{ .i64 = 7 });

    // Everything below is over the limit and must be dropped, not recorded.
    const second = [_]api.AttributeKeyValue{
        .{ .key = "slot", .value = .{ .string = "b" } },
    };
    const overflow_f64 = map.getOrCreateAggregation(&second, gauge_meta, 1, .{ .f64 = 1.5 });
    const overflow_i64 = map.getOrCreateAggregation(&second, counter_meta, 2, .{ .i64 = 9 });

    try testing.expectEqual(AggregationTag.drop, std.meta.activeTag(overflow_f64.aggregation));
    try testing.expectEqual(AggregationTag.drop, std.meta.activeTag(overflow_i64.aggregation));

    // Neither value type may abort, and nothing may be recorded.
    try testing.expect(!overflow_f64.aggregation.record(@as(f64, 1.0)));
    try testing.expect(!overflow_f64.aggregation.record(@as(i64, 1)));
    overflow_f64.aggregation.add(@as(i64, 1));
    overflow_i64.aggregation.add(@as(f64, 1.0));

    try testing.expectEqual(@as(usize, 1), map.getCardinality());
}

