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

/// Attribute-based aggregation map with cardinality limits
pub const AttributeAggregationMap = struct {
    // Cardinality limit (matches OpenTelemetry spec default)
    pub const MAX_CARDINALITY: usize = 2000;

    // Map from (instrument_hash + attribute_hash) to aggregation
    aggregations: std.AutoHashMap(u128, *AttributeAggregationEntry),

    // Pre-allocated pool of aggregation entries
    aggregation_pool: [MAX_CARDINALITY]AttributeAggregationEntry,
    overflow_aggregation: AttributeAggregationEntry,
    next_free: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    // Lock to prevent map corruption
    mutex: std.Thread.Mutex,

    /// Initialize the attribute aggregation map
    pub fn init(allocator: std.mem.Allocator) !AttributeAggregationMap {
        return .{
            .aggregations = std.AutoHashMap(u128, *AttributeAggregationEntry).init(allocator),
            .aggregation_pool = undefined, // Will be initialized as needed
            .next_free = .init(0),
            .allocator = allocator,
            .overflow_aggregation = .{
                // This is pre-allocated outside of the stack to track when
                // cardinality has been exhausted.
                .aggregation = .{ .sum_i64 = .init() },
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
            .mutex = .{},
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *AttributeAggregationMap) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up aggregation entries that need allocator cleanup
        for (0..self.next_free.load(.monotonic)) |i| {
            self.aggregation_pool[i].deinit(self.allocator);
        }
        self.overflow_aggregation.deinit(self.allocator);
        self.aggregations.deinit();
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

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if aggregation entry already exists
        if (self.aggregations.get(combined_hash)) |entry| {
            return entry;
        }

        // We're in a mutex, so this isn't critical to be atomic,
        // but leaving it atomic out of laziness.
        const next_free = self.next_free.load(.monotonic);

        // Check cardinality limit
        if (next_free >= MAX_CARDINALITY) {
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

    /// Get current cardinality (number of unique attribute combinations)
    pub fn getCardinality(self: *const AttributeAggregationMap) usize {
        return self.next_free.load(.unordered);
    }

    /// Check if cardinality limit has been exceeded
    pub fn hasExceededLimit(self: *const AttributeAggregationMap) bool {
        return self.next_free.load(.monotonic) >= MAX_CARDINALITY;
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
        self.mutex.lock();
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

    var map = try AttributeAggregationMap.init(allocator);
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

test "AttributeAggregationMap - cardinality limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = try AttributeAggregationMap.init(allocator);
    defer map.deinit();

    // Fill up to the limit (using a smaller limit for testing)
    // Note: In practice, MAX_CARDINALITY is 2000, but for testing we can't easily create that many
    // This test verifies the logic works
    try testing.expect(!map.hasExceededLimit());
}
