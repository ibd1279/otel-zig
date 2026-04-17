//! Reader Aggregation State for OpenTelemetry Metrics SDK
//!
//! This module manages aggregation state per reader, allowing multiple readers
//! to maintain independent aggregation states for the same instruments.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const AttributeAggregationMap = @import("attribute_aggregation_map.zig").AttributeAggregationMap;
    const AttributeAggregationEntry = @import("attribute_aggregation_map.zig").AttributeAggregationEntry;
    const InstrumentType = @import("metadata.zig").InstrumentType;
    const MetricData = @import("data.zig").MetricData;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("reader.zig").MetricValue;
    const Resource = @import("../resource/resource.zig").Resource;
    const aggregations = @import("aggregations.zig");
};

pub const AggregationTemporality = sdk.aggregations.AggregationTemporality;
pub const AggregationType = sdk.aggregations.AggregationType;

/// Function type for selecting aggregation based on instrument type
pub const AggregationSelector = *const fn (instrument_type: sdk.InstrumentType) AggregationType;

/// Default aggregation selector based on instrument type
pub fn defaultAggregationSelector(instrument_type: sdk.InstrumentType) AggregationType {
    return switch (instrument_type) {
        .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => .sum,
        .Gauge, .ObservableGauge => .last_value,
        .Histogram => .histogram,
    };
}

/// Per-reader aggregation state management
pub const ReaderAggregationState = struct {
    // Phase 1b: Attribute-based aggregation map with cardinality limits
    aggregations: sdk.AttributeAggregationMap,
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex,

    // Reader's configured temporality
    temporality: AggregationTemporality,

    // Aggregation selector (determines aggregation type per instrument)
    aggregation_selector: AggregationSelector,

    // For cumulative temporality, track last collection time
    last_collection_time: std.Io.Timestamp,

    /// Initialize reader aggregation state
    pub fn init(
        allocator: std.mem.Allocator,
        temporality: AggregationTemporality,
        aggregation_selector: AggregationSelector,
    ) !@This() {
        return .{
            .aggregations = try sdk.AttributeAggregationMap.init(allocator),
            .allocator = allocator,
            .mutex = .unlocked,
            .temporality = temporality,
            .aggregation_selector = aggregation_selector,
            .last_collection_time = std.Io.Timestamp.zero,
        };
    }

    /// Clean up all aggregations and resources
    pub fn deinit(self: *@This()) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        // Clean up the attribute aggregation map
        self.aggregations.deinit();
    }

    /// Record a measurement from an instrument.
    /// Holds the aggregation map mutex across both the lookup and the add()/record()
    /// call so that snapshot() cannot free the entry between the two operations.
    /// Callers must not hold any other locks when calling this function.
    pub fn recordMeasurement(
        self: *@This(),
        value: sdk.MetricValue,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
    ) void {
        while (!self.aggregations.mutex.tryLock()) {}
        defer self.aggregations.mutex.unlock();

        const agg = self.aggregations.getOrCreateAggregationLocked(attributes, metadata, metadata_hash, value);

        switch (metadata.instrument_type) {
            .Counter, .UpDownCounter => switch (value) {
                .i64 => |v| agg.aggregation.add(v),
                .f64 => |v| agg.aggregation.add(v),
            },
            else => switch (value) {
                .i64 => |v| _ = agg.aggregation.record(v),
                .f64 => |v| _ = agg.aggregation.record(v),
            },
        }
    }

    /// Collect metrics from all aggregations (lock-free aggregation access)
    pub fn collect(self: *@This(), allocator: std.mem.Allocator, io: std.Io, resource: sdk.Resource) ![]sdk.MetricData {
        // Lock only for map iteration, aggregation data access is lock-free
        var entry_list = std.ArrayList(sdk.AttributeAggregationEntry).empty;
        defer entry_list.deinit(allocator);

        // Copy aggregation entry pointers under lock
        try self.aggregations.snapshot(allocator, &entry_list, io);

        var metrics_list = std.ArrayList(sdk.MetricData).empty;
        errdefer metrics_list.deinit(allocator);

        const current_timestamp = std.Io.Clock.real.now(io);

        // Process aggregation entries lock-free (atomic reads)
        for (entry_list.items) |*entry| {
            // Create metric data based on aggregation type (lock-free atomic reads)
            const metric_data = try self.createMetricDataFromAggregationEntry(
                allocator,
                entry,
                current_timestamp,
                resource,
            );

            if (metric_data) |data| {
                try metrics_list.append(allocator, data);
            }
        }

        return metrics_list.toOwnedSlice(allocator);
    }

    /// Convert a single aggregation entry to MetricData
    fn createMetricDataFromAggregationEntry(
        self: *@This(),
        allocator: std.mem.Allocator,
        entry: *sdk.AttributeAggregationEntry,
        timestamp: std.Io.Timestamp,
        resource: sdk.Resource,
    ) !?sdk.MetricData {
        _ = self; // Not used in this helper method

        // Create data points array with single point
        const data_points = try allocator.alloc(sdk.MetricDataPoint, 1);
        errdefer allocator.free(data_points);

        // Clone attributes from the entry for export
        // const export_attributes = try allocator.alloc(api.AttributeKeyValue, entry.attributes.len);
        // @memcpy(export_attributes, entry.attributes);
        const export_attributes = entry.attributes;

        switch (entry.aggregation) {
            .sum_i64 => |*sum| {
                data_points[0] = sdk.MetricDataPoint{
                    .timestamp = timestamp,
                    .start_timestamp = sum.start_timestamp,
                    .attributes = export_attributes,
                    .value = .{ .i64_sum = sum.value.load(.monotonic) },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .sum,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = resource,
                };
            },
            .sum_f64 => |*sum| {
                data_points[0] = sdk.MetricDataPoint{
                    .timestamp = timestamp,
                    .start_timestamp = sum.start_timestamp,
                    .attributes = export_attributes,
                    .value = .{ .f64_sum = sum.value.load(.monotonic) },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .sum,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = resource,
                };
            },
            .last_value_i64 => |*lv| {
                const value = lv.getValue();
                if (value == null) {
                    // No value recorded, skip this gauge
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp = timestamp,
                    .start_timestamp = null, // Last value doesn't have start time
                    .attributes = export_attributes,
                    .value = .{ .i64_gauge = value.? },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .gauge,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = resource,
                };
            },
            .last_value_f64 => |*lv| {
                const value = lv.getValue();
                if (value == null) {
                    // No value recorded, skip this gauge
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp = timestamp,
                    .start_timestamp = null, // Last value doesn't have start time
                    .attributes = export_attributes,
                    .value = .{ .f64_gauge = value.? },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .gauge,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = resource,
                };
            },
            .histogram_i64 => |*hist| {
                if (hist.getCount() == 0) {
                    // No data recorded, skip this histogram
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                // Copy atomic bucket counts to regular u64 array
                const bucket_counts = try allocator.alloc(u64, hist.counts.len);
                for (hist.counts, 0..) |*atomic_count, i| {
                    bucket_counts[i] = atomic_count.load(.monotonic);
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp = timestamp,
                    .start_timestamp = hist.start_timestamp,
                    .attributes = export_attributes,
                    .value = .{
                        .i64_histogram = .{
                            .count = hist.getCount(),
                            .sum = hist.getSum(),
                            .min = hist.getMin(),
                            .max = hist.getMax(),
                            .boundaries = hist.boundaries,
                            .bucket_counts = bucket_counts,
                        },
                    },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .histogram,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = resource,
                };
            },
            .histogram_f64 => |*hist| {
                if (hist.getCount() == 0) {
                    // No data recorded, skip this histogram
                    allocator.free(data_points);
                    allocator.free(export_attributes);
                    return null;
                }

                // Copy atomic bucket counts to regular u64 array
                const bucket_counts = try allocator.alloc(u64, hist.counts.len);
                for (hist.counts, 0..) |*atomic_count, i| {
                    bucket_counts[i] = atomic_count.load(.monotonic);
                }

                data_points[0] = sdk.MetricDataPoint{
                    .timestamp = timestamp,
                    .start_timestamp = hist.start_timestamp,
                    .attributes = export_attributes,
                    .value = .{
                        .f64_histogram = .{
                            .count = hist.getCount(),
                            .sum = hist.getSum(),
                            .min = hist.getMin(),
                            .max = hist.getMax(),
                            .boundaries = hist.boundaries,
                            .bucket_counts = bucket_counts,
                        },
                    },
                };
                return sdk.MetricData{
                    .name = entry.metadata.name,
                    .description = if (entry.metadata.description.len > 0) entry.metadata.description else null,
                    .unit = if (entry.metadata.unit.len > 0) entry.metadata.unit else null,
                    .type = .histogram,
                    .data_points = data_points,
                    .scope = entry.metadata.instrumentation_scope,
                    .resource = resource,
                };
            },
            .drop => {
                // Drop aggregation produces no metric data
                allocator.free(data_points);
                allocator.free(export_attributes);
                return null;
            },
        }
    }
};

test "ReaderAggregationState - concurrent recordMeasurement and snapshot" {
    // page_allocator is used because testing.allocator is not thread-safe
    // and GeneralPurposeAllocator was removed in Zig 0.16.
    const allocator = std.heap.page_allocator;

    var state = try ReaderAggregationState.init(allocator, .delta, defaultAggregationSelector);
    defer state.deinit();

    const scope: api.InstrumentationScope = .{
        .name = "test.concurrent",
        .version = null,
        .schema_url = null,
        .attributes = &[_]api.AttributeKeyValue{},
    };
    const metadata: sdk.MetricMetadata = .{
        .name = "test.counter",
        .description = "stress test counter",
        .unit = "1",
        .instrument_type = .Counter,
        .instrumentation_scope = scope,
    };
    const metadata_hash = sdk.MetricMetadata.computeHash(
        metadata.name,
        metadata.unit,
        metadata.instrument_type,
        &metadata.instrumentation_scope,
    );
    const num_writers = 4;
    const writes_per_writer = 500;
    const num_collectors = 2;
    const collections_per_collector = 50;

    // Writer thread: calls recordMeasurement repeatedly.
    const WriterArgs = struct {
        state_ptr: *ReaderAggregationState,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
    };
    const writerFn = struct {
        fn run(args: WriterArgs) void {
            const attrs = [_]api.AttributeKeyValue{};
            for (0..writes_per_writer) |_| {
                args.state_ptr.recordMeasurement(.{ .i64 = 1 }, &attrs, args.metadata, args.metadata_hash);
            }
        }
    }.run;

    // Collector thread: calls collect() repeatedly, freeing each result.
    const CollectorArgs = struct {
        state_ptr: *ReaderAggregationState,
        resource: sdk.Resource,
    };
    const collectorFn = struct {
        fn run(args: CollectorArgs) void {
            const alloc = std.heap.page_allocator;
            for (0..collections_per_collector) |_| {
                const metrics = args.state_ptr.collect(alloc, std.testing.io, args.resource) catch continue;
                for (metrics) |metric| {
                    for (metric.data_points) |dp| {
                        switch (dp.value) {
                            .i64_histogram => |h| alloc.free(h.bucket_counts),
                            .f64_histogram => |h| alloc.free(h.bucket_counts),
                            else => {},
                        }
                    }
                    alloc.free(metric.data_points);
                }
                alloc.free(metrics);
            }
        }
    }.run;

    var writer_threads: [num_writers]std.Thread = undefined;
    var collector_threads: [num_collectors]std.Thread = undefined;

    const writer_args = WriterArgs{
        .state_ptr = &state,
        .metadata = metadata,
        .metadata_hash = metadata_hash,
    };
    const collector_args = CollectorArgs{
        .state_ptr = &state,
        .resource = sdk.Resource.empty,
    };

    for (0..num_writers) |i| {
        writer_threads[i] = try std.Thread.spawn(.{}, writerFn, .{writer_args});
    }
    for (0..num_collectors) |i| {
        collector_threads[i] = try std.Thread.spawn(.{}, collectorFn, .{collector_args});
    }

    for (writer_threads) |t| t.join();
    for (collector_threads) |t| t.join();

    // A final collect must not crash and must return a non-negative sum.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const final_metrics = try state.collect(arena.allocator(), std.testing.io, sdk.Resource.empty);
    var total_sum: i64 = 0;
    for (final_metrics) |metric| {
        for (metric.data_points) |dp| {
            switch (dp.value) {
                .i64_sum => |v| total_sum += v,
                else => {},
            }
        }
    }
    try std.testing.expect(total_sum >= 0);
}
