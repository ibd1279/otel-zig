const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const ManualReader = @import("manual_reader.zig").ManualReader;
    const Meter = @import("meter.zig").Meter;
    const MeterProvider = @import("meter_provider.zig").MeterProvider;
    const MetricData = @import("data.zig").MetricData;
    const MetricType = @import("data.zig").MetricType;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
    const PeriodicReader = @import("periodic_reader.zig").PeriodicReader;
    const Resource = @import("../resource/resource.zig").Resource;
    const aggregations = @import("aggregations.zig");
};

// Import test dependencies
const MockMetricExporter = @import("exporter.zig").MockMetricExporter;

// Helper function to cleanup MetricData memory
fn cleanupMetrics(allocator: std.mem.Allocator, metrics: []sdk.MetricData) void {
    for (metrics) |metric| {
        // Free histogram bucket_counts if present (must do this before freeing data_points)
        for (metric.data_points) |data_point| {
            switch (data_point.value) {
                .i64_histogram => |hist| allocator.free(hist.bucket_counts),
                .f64_histogram => |hist| allocator.free(hist.bucket_counts),
                else => {},
            }
        }

        // Free data_points array
        allocator.free(metric.data_points);
    }
    allocator.free(metrics);
}

test "BasicMeterProvider lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create resource
    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    try testing.expect(provider.readers.items.len == 0);
    try testing.expect(provider.cache.count() == 0);
}

test "BasicMeterProvider meter caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const scope1 = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    const scope2 = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" }; // Same
    const scope3 = api.InstrumentationScope{ .name = "other.meter", .version = "1.0.0" }; // Different

    const meter1 = try provider.getMeterWithScope(scope1);
    const meter2 = try provider.getMeterWithScope(scope2);
    const meter3 = try provider.getMeterWithScope(scope3);

    // Same scope should return same meter instance
    try testing.expect(meter1.bridge.meter_ptr == meter2.bridge.meter_ptr);
    try testing.expect(meter1.bridge.meter_ptr != meter3.bridge.meter_ptr);

    // Verify cache contains 2 unique entries
    try testing.expectEqual(@as(u32, 2), provider.cache.count());
}

test "BasicMeterProvider processor registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    try @import("../common/pipeline.zig").PipelineBuilder(*sdk.MeterProvider).init(&provider)
        .with(sdk.ManualReader.PipelineStep.init(.{ .io = std.testing.io }).flowTo(MockMetricExporter.PipelineStep.init({})))
        .done();

    try testing.expectEqual(@as(usize, 1), provider.readers.items.len);
}

test "BasicMeter instrument creation and data collection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create various instrument types
    const counter_i64 = try meter.createCounter(i64, "test.counter.i64", "Test counter", "requests", null);
    const counter_f64 = try meter.createCounter(f64, "test.counter.f64", "Test counter", "seconds", null);
    const updown_i64 = try meter.createUpDownCounter(i64, "test.updown.i64", "Test updown", "connections", null);
    const gauge_i64 = try meter.createGauge(i64, "test.gauge.i64", "Test gauge", "bytes", null);
    const histogram_f64 = try meter.createHistogram(f64, "test.histogram.f64", "Test histogram", "ms", null);

    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    // Record some measurements
    counter_i64.add(ctx, 10, &empty_attributes);
    counter_i64.add(ctx, 5, &empty_attributes);
    counter_f64.add(ctx, 3.14, &empty_attributes);
    updown_i64.add(ctx, 5, &empty_attributes);
    updown_i64.add(ctx, -2, &empty_attributes);
    gauge_i64.record(ctx, 42, &empty_attributes);
    histogram_f64.record(ctx, 15.5, &empty_attributes);
    histogram_f64.record(ctx, 25.0, &empty_attributes);

    // Note: provider has no configured readers, so this is mostly a dead-end test.
}

test "BasicMeter data collection through processor pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);
    // Processor takes ownership of this memory

    // Create processor (heap-allocated)
    const reader = try allocator.create(sdk.ManualReader);
    reader.* = try sdk.ManualReader.init(allocator, std.testing.io, mock_exporter.metricExporter());

    // Register reader (provider takes ownership)
    try provider.registerReader(reader.reader());

    // Get meter
    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create instruments and record data
    const counter = try meter.createCounter(i64, "http.requests", "HTTP requests", "requests", null);
    const histogram = try meter.createHistogram(f64, "http.duration", "HTTP duration", "ms", null);

    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    counter.add(ctx, 5, &empty_attributes);
    counter.add(ctx, 3, &empty_attributes);
    histogram.record(ctx, 12.5, &empty_attributes);
    histogram.record(ctx, 25.0, &empty_attributes);

    // Force collection via processor (pull model)
    reader.collect();

    // Verify metrics were exported
    try testing.expect(mock_exporter.metricCount() > 0);

    // Check that we have the expected metric types
    var buffer: [1]sdk.MetricData = undefined;

    const counter_matches = mock_exporter.getMetricsNamed(&buffer, "http.requests");
    try testing.expectEqual(@as(usize, 1), counter_matches.len);
    try testing.expectEqual(sdk.MetricType.sum, counter_matches[0].type);
    try testing.expect(counter_matches[0].data_points.len > 0);

    const histogram_matches = mock_exporter.getMetricsNamed(&buffer, "http.duration");
    try testing.expectEqual(@as(usize, 1), histogram_matches.len);
    try testing.expectEqual(sdk.MetricType.histogram, histogram_matches[0].type);
    try testing.expect(histogram_matches[0].data_points.len > 0);
}

test "BasicMeter shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create counter and record data before shutdown
    const counter = try meter.createCounter(i64, "test.counter", "Test counter", "requests", null);
    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    counter.add(ctx, 10, &empty_attributes);

    // Get the BasicMeter instance for direct access
    const basic_meter: *sdk.Meter = @ptrCast(@alignCast(meter.bridge.meter_ptr));

    // TODO: Phase 1b - Re-enable once collection is implemented at reader level
    // // Verify data exists before shutdown
    // const metrics_before = try basic_meter.collectMetrics(allocator);
    // defer cleanupMetrics(allocator, metrics_before);
    // try testing.expect(metrics_before.len > 0);

    // Shutdown the meter
    basic_meter.shutdown();
    try testing.expect(basic_meter.is_shutdown.load(.unordered));

    // TODO: Phase 1b - Re-enable once collection is implemented at reader level
    // // Test that collectMetrics still works after shutdown (data preserved)
    // const metrics_after = try basic_meter.collectMetrics(allocator);
    // defer cleanupMetrics(allocator, metrics_after);
    // try testing.expect(metrics_after.len > 0);

    // TODO: The following test should work when shutdown behavior is fully implemented
    // Currently commented out as it may not be implemented yet
    //
    // // Try to record new data after shutdown - should be ignored
    // counter.add(ctx, 5, &empty_attributes);
    //
    // // Verify the counter value didn't change
    // const metrics_final = try basic_meter.collectMetrics(allocator);
    // defer allocator.free(metrics_final);
    // // Should still have same data as before the post-shutdown recording
}

test "BasicMeterProvider flush behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);

    const reader = try allocator.create(sdk.ManualReader);
    reader.* = try sdk.ManualReader.init(allocator, std.testing.io, mock_exporter.metricExporter());

    try provider.registerReader(reader.reader());

    // Test successful flush
    const result = provider.forceFlush(1000);
    try testing.expectEqual(api.common.FlushResult.success, result);

    // Test flush with failure
    mock_exporter.flush_result = .failure;
    const result2 = provider.forceFlush(1000);
    try testing.expectEqual(api.common.FlushResult.failure, result2);
}

test "BasicMeter comprehensive instrument test with attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Test custom histogram boundaries (for future use)
    _ = [_]f64{ 0.0, 1.0, 5.0, 10.0, 50.0 };

    // Create all instrument types with different value types
    const counter_i64 = try meter.createCounter(i64, "test.counter.i64", "Test i64 counter", "ops", null);
    const counter_f64 = try meter.createCounter(f64, "test.counter.f64", "Test f64 counter", "seconds", null);
    const updown_i64 = try meter.createUpDownCounter(i64, "test.updown.i64", "Test i64 updown", "items", null);
    const updown_f64 = try meter.createUpDownCounter(f64, "test.updown.f64", "Test f64 updown", "temperature", null);
    const gauge_i64 = try meter.createGauge(i64, "test.gauge.i64", "Test i64 gauge", "bytes", null);
    const gauge_f64 = try meter.createGauge(f64, "test.gauge.f64", "Test f64 gauge", "ratio", null);
    const histogram_i64 = try meter.createHistogram(i64, "test.histogram.i64", "Test i64 histogram", "count", null);
    const histogram_f64 = try meter.createHistogram(f64, "test.histogram.f64", "Test f64 histogram", "latency", null);

    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    // Record various measurements
    counter_i64.add(ctx, 15, &empty_attributes);
    counter_i64.add(ctx, 25, &empty_attributes); // Total: 40
    counter_f64.add(ctx, 3.14, &empty_attributes);
    counter_f64.add(ctx, 2.86, &empty_attributes); // Total: 6.0

    updown_i64.add(ctx, 10, &empty_attributes);
    updown_i64.add(ctx, -3, &empty_attributes); // Total: 7
    updown_f64.add(ctx, 5.5, &empty_attributes);
    updown_f64.add(ctx, -1.5, &empty_attributes); // Total: 4.0

    gauge_i64.record(ctx, 1024, &empty_attributes);
    gauge_i64.record(ctx, 2048, &empty_attributes); // Last: 2048
    gauge_f64.record(ctx, 0.85, &empty_attributes);
    gauge_f64.record(ctx, 0.92, &empty_attributes); // Last: 0.92

    // Test histogram with various values to hit different buckets
    histogram_i64.record(ctx, 2, &empty_attributes); // bucket 1 (1-5)
    histogram_i64.record(ctx, 7, &empty_attributes); // bucket 2 (5-10)
    histogram_i64.record(ctx, 15, &empty_attributes); // bucket 3 (10-50)
    histogram_f64.record(ctx, 0.5, &empty_attributes); // bucket 0 (0-1)
    histogram_f64.record(ctx, 3.2, &empty_attributes); // bucket 1 (1-5)
    histogram_f64.record(ctx, 25.0, &empty_attributes); // bucket 3 (10-50)

    // There are no readers configured on the provider, so this is a dead-end test.
}

test "BasicMeter instrument creation after shutdown returns noop instruments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create instrument before shutdown - should be normal SDK instrument
    const counter_before = try meter.createCounter(i64, "test.counter.before", "Test counter", "requests", null);
    try testing.expect(counter_before == .bridge); // Should be bridge to SDK instrument

    // Get the BasicMeter instance to shutdown directly
    const basic_meter: *sdk.Meter = @ptrCast(@alignCast(meter.bridge.meter_ptr));
    basic_meter.shutdown();

    // Create instruments after shutdown - should be noop instruments
    const counter_after = try meter.createCounter(i64, "test.counter.after", "Test counter", "requests", null);
    const updown_after = try meter.createUpDownCounter(f64, "test.updown.after", "Test updown", "bytes", null);
    const gauge_after = try meter.createGauge(i64, "test.gauge.after", "Test gauge", "items", null);
    const histogram_after = try meter.createHistogram(f64, "test.histogram.after", "Test histogram", "ms", null);

    // All instruments created after shutdown should be noop
    try testing.expect(counter_after == .noop);
    try testing.expect(updown_after == .noop);
    try testing.expect(gauge_after == .noop);
    try testing.expect(histogram_after == .noop);

    // Verify noop instruments have the correct names
    try testing.expectEqualStrings("test.counter.after", counter_after.noop);
    try testing.expectEqualStrings("test.updown.after", updown_after.noop);
    try testing.expectEqualStrings("test.gauge.after", gauge_after.noop);
    try testing.expectEqualStrings("test.histogram.after", histogram_after.noop);
}

test "PeriodicReader with multiple instruments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);
    // Processor takes ownership of this memory

    // Create periodic reader with 100ms interval
    const reader = try allocator.create(sdk.PeriodicReader);
    reader.* = try sdk.PeriodicReader.init(allocator, std.testing.io, mock_exporter.metricExporter(), 100);

    // Register reader (provider takes ownership)
    try provider.registerReader(reader.reader());

    // Get meter
    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create regular instruments
    const counter = try meter.createCounter(i64, "test.counter", "Test counter", "requests", null);
    const gauge = try meter.createGauge(f64, "test.gauge", "Test gauge", "ratio", null);
    const histogram = try meter.createHistogram(i64, "test.histogram", "Test histogram", "count", null);

    // Create observable instruments
    const observable_counter = try meter.createObservableCounter(i64, "test.observable.counter", "Test observable counter", "requests", null, &[_]api.metrics.TypeErasedCallback(i64){});
    const observable_gauge = try meter.createObservableGauge(f64, "test.observable.gauge", "Test observable gauge", "ratio", null, &[_]api.metrics.TypeErasedCallback(f64){});
    const observable_updown = try meter.createObservableUpDownCounter(i64, "test.observable.updown", "Test observable updown", "items", null, &[_]api.metrics.TypeErasedCallback(i64){});

    // Record some data with regular instruments
    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    counter.add(ctx, 10, &empty_attributes);
    counter.add(ctx, 5, &empty_attributes);
    gauge.record(ctx, 0.75, &empty_attributes);
    histogram.record(ctx, 15, &empty_attributes);
    histogram.record(ctx, 25, &empty_attributes);

    // Setup callbacks for observable instruments
    const counter_callback = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(i64)) void {
            result.observe(alloc, 42, &empty_attributes);
        }
    }.callback;
    const gauge_callback = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(f64)) void {
            result.observe(alloc, 0.95, &empty_attributes);
        }
    }.callback;
    const updown_callback = struct {
        fn callback(alloc: std.mem.Allocator, result: *api.metrics.ObservableResult(i64)) void {
            result.observe(alloc, 100, &empty_attributes);
        }
    }.callback;

    // Register the callbacks
    const counter_handle = try observable_counter.registerCallbackNoState(counter_callback);
    const gauge_handle = try observable_gauge.registerCallbackNoState(gauge_callback);
    const updown_handle = try observable_updown.registerCallbackNoState(updown_callback);

    defer {
        counter_handle.unregister();
        gauge_handle.unregister();
        updown_handle.unregister();
    }

    // Wait for periodic collection to happen (simulate time passing)
    try std.Io.sleep(std.testing.io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake);

    // Force a final collection
    reader.collect();

    // Verify metrics were exported
    try testing.expect(mock_exporter.metricCount() > 0);

    // Check that we have the expected metric types
    var buffer: [1]sdk.MetricData = undefined;

    const counter_matches = mock_exporter.getMetricsNamed(&buffer, "test.counter");
    try testing.expectEqual(@as(usize, 1), counter_matches.len);
    try testing.expectEqual(sdk.MetricType.sum, counter_matches[0].type);
    try testing.expect(counter_matches[0].data_points.len > 0);

    const gauge_matches = mock_exporter.getMetricsNamed(&buffer, "test.gauge");
    try testing.expectEqual(@as(usize, 1), gauge_matches.len);
    try testing.expectEqual(sdk.MetricType.gauge, gauge_matches[0].type);
    try testing.expect(gauge_matches[0].data_points.len > 0);

    const histogram_matches = mock_exporter.getMetricsNamed(&buffer, "test.histogram");
    try testing.expectEqual(@as(usize, 1), histogram_matches.len);
    try testing.expectEqual(sdk.MetricType.histogram, histogram_matches[0].type);
    try testing.expect(histogram_matches[0].data_points.len > 0);

    const observable_counter_matches = mock_exporter.getMetricsNamed(&buffer, "test.observable.counter");
    try testing.expectEqual(@as(usize, 1), observable_counter_matches.len);
    try testing.expectEqual(sdk.MetricType.sum, observable_counter_matches[0].type);
    try testing.expect(observable_counter_matches[0].data_points.len > 0);

    const observable_gauge_matches = mock_exporter.getMetricsNamed(&buffer, "test.observable.gauge");
    try testing.expectEqual(@as(usize, 1), observable_gauge_matches.len);
    try testing.expectEqual(sdk.MetricType.gauge, observable_gauge_matches[0].type);
    try testing.expect(observable_gauge_matches[0].data_points.len > 0);

    const observable_updown_matches = mock_exporter.getMetricsNamed(&buffer, "test.observable.updown");
    try testing.expectEqual(@as(usize, 1), observable_updown_matches.len);
    try testing.expectEqual(sdk.MetricType.sum, observable_updown_matches[0].type);
    try testing.expect(observable_updown_matches[0].data_points.len > 0);
}

test "Meter returns same instrument pointer for identical instruments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Test sync instrument (Counter) - request same instrument twice
    const counter1 = try meter.createCounter(i64, "test.counter", "Test counter", "requests", null);
    const counter2 = try meter.createCounter(i64, "test.counter", "Test counter", "requests", null);

    // Both should be bridge types pointing to the same SDK instrument
    try testing.expect(counter1 == .bridge);
    try testing.expect(counter2 == .bridge);
    try testing.expectEqual(counter1.bridge.instrument_ptr, counter2.bridge.instrument_ptr);

    // Test async instrument (ObservableCounter) - request same instrument twice
    const empty_callbacks = [_]api.metrics.TypeErasedCallback(i64){};
    const observable1 = try meter.createObservableCounter(i64, "test.observable", "Test observable", "requests", null, &empty_callbacks);
    const observable2 = try meter.createObservableCounter(i64, "test.observable", "Test observable", "requests", null, &empty_callbacks);

    // Both should be bridge types pointing to the same SDK instrument
    try testing.expect(observable1 == .bridge);
    try testing.expect(observable2 == .bridge);
    try testing.expectEqual(observable1.bridge.instrument_ptr, observable2.bridge.instrument_ptr);
}

test "Histogram uses advisory explicit bucket boundaries" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockMetricExporter);
    mock_exporter.* = MockMetricExporter.init(allocator);

    const reader = try allocator.create(sdk.ManualReader);
    reader.* = try sdk.ManualReader.init(allocator, std.testing.io, mock_exporter.metricExporter());

    try provider.registerReader(reader.reader());

    const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
    var meter = try provider.getMeterWithScope(scope);

    // Create custom bucket boundaries
    const custom_boundaries = [_]f64{ 0.0, 10.0, 50.0, 100.0 };
    const advisory_params = api.metrics.AdvisoryParams{
        .explicit_bucket_boundaries = &custom_boundaries,
        .attributes = null,
    };

    // Create histogram with advisory boundaries
    const histogram = try meter.createHistogram(f64, "test.histogram", "Test histogram", "ms", advisory_params);

    const ctx = &[_]api.ContextKeyValue{};
    const empty_attributes = [_]api.AttributeKeyValue{};

    // Record measurements that fall into different buckets
    histogram.record(ctx, 5.0, &empty_attributes); // bucket 0 (0-10)
    histogram.record(ctx, 25.0, &empty_attributes); // bucket 1 (10-50)
    histogram.record(ctx, 75.0, &empty_attributes); // bucket 2 (50-100)
    histogram.record(ctx, 150.0, &empty_attributes); // bucket 3 (100-∞)

    // Force collection
    reader.collect();

    // Find the histogram metric using helper
    var buffer: [1]sdk.MetricData = undefined;
    const matches = mock_exporter.getMetricsNamed(&buffer, "test.histogram");
    try testing.expectEqual(@as(usize, 1), matches.len);

    const metric = matches[0];
    try testing.expectEqual(sdk.MetricType.histogram, metric.type);
    try testing.expect(metric.data_points.len > 0);

    // Check that the histogram used our custom boundaries
    const data_point = metric.data_points[0];
    switch (data_point.value) {
        .f64_histogram => |hist| {
            // We should have 5 buckets: [0-10), [10-50), [50-100), [100-∞), and implicit (-∞-0)
            // The bucket_counts length should be boundaries.len + 1
            try testing.expectEqual(@as(usize, 5), hist.bucket_counts.len);

            // Verify we got measurements in the expected buckets
            try testing.expectEqual(@as(u64, 1), hist.bucket_counts[1]); // 5.0 in [0-10)
            try testing.expectEqual(@as(u64, 1), hist.bucket_counts[2]); // 25.0 in [10-50)
            try testing.expectEqual(@as(u64, 1), hist.bucket_counts[3]); // 75.0 in [50-100)
            try testing.expectEqual(@as(u64, 1), hist.bucket_counts[4]); // 150.0 in [100-∞)
        },
        else => try testing.expect(false), // Should be f64_histogram
    }
}

test "Advisory attributes filtering with and without views" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Part 1: Test advisory attributes without views
    {
        const resource = try sdk.Resource.initOwned(allocator, .default);
        var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
        defer provider.deinit();

        const mock_exporter = try allocator.create(MockMetricExporter);
        mock_exporter.* = MockMetricExporter.init(allocator);

        const reader = try allocator.create(sdk.ManualReader);
        reader.* = try sdk.ManualReader.init(allocator, std.testing.io, mock_exporter.metricExporter());

        try provider.registerReader(reader.reader());

        const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
        var meter = try provider.getMeterWithScope(scope);

        // Create counter with advisory attributes filtering
        const allowed_attributes = [_][]const u8{ "method", "status" };
        const advisory_params = api.metrics.AdvisoryParams{
            .explicit_bucket_boundaries = null,
            .attributes = &allowed_attributes,
        };

        const counter = try meter.createCounter(i64, "test.counter", "Test counter", "requests", advisory_params);

        const ctx = &[_]api.ContextKeyValue{};

        // Record measurements with multiple attributes
        // Advisory params specify only "method" and "status" should be kept
        const all_attributes = [_]api.AttributeKeyValue{
            .{ .key = "method", .value = .{ .string = "GET" } },
            .{ .key = "status", .value = .{ .int = 200 } },
            .{ .key = "user_id", .value = .{ .string = "12345" } }, // Should be filtered out by advisory
        };

        counter.add(ctx, 10, &all_attributes);

        // Force collection
        reader.collect();

        // Verify the counter metric was exported with filtered attributes
        var buffer: [1]sdk.MetricData = undefined;
        const matches = mock_exporter.getMetricsNamed(&buffer, "test.counter");
        try testing.expectEqual(@as(usize, 1), matches.len);

        const metric = matches[0];
        try testing.expect(metric.data_points.len > 0);

        // Check that only advisory-allowed attributes are present
        const data_point = metric.data_points[0];
        try testing.expectEqual(@as(usize, 2), data_point.attributes.len);

        var found_method = false;
        var found_status = false;
        var found_user_id = false;

        for (data_point.attributes) |attr| {
            if (std.mem.eql(u8, attr.key, "method")) found_method = true;
            if (std.mem.eql(u8, attr.key, "status")) found_status = true;
            if (std.mem.eql(u8, attr.key, "user_id")) found_user_id = true;
        }

        try testing.expect(found_method);
        try testing.expect(found_status);
        try testing.expect(!found_user_id); // Should have been filtered out
    }

    // Part 2: Test with a view that overrides advisory params
    {
        const resource = try sdk.Resource.initOwned(allocator, .default);
        var provider = sdk.MeterProvider.init(allocator, std.testing.io, resource);
        defer provider.deinit();

        // Register a view that filters to only "user_id"
        const view_allowed_attributes = [_][]const u8{"user_id"};
        const view = @import("view.zig"){
            .instrument_selector = .{ .name = "test.counter" },
            .name = null,
            .description = null,
            .attribute_allowed_keys = &view_allowed_attributes,
            .aggregation_override = null,
        };
        try provider.addView(view);

        const mock_exporter = try allocator.create(MockMetricExporter);
        mock_exporter.* = MockMetricExporter.init(allocator);

        const reader = try allocator.create(sdk.ManualReader);
        reader.* = try sdk.ManualReader.init(allocator, std.testing.io, mock_exporter.metricExporter());

        try provider.registerReader(reader.reader());

        const scope = api.InstrumentationScope{ .name = "test.meter", .version = "1.0.0" };
        var meter = try provider.getMeterWithScope(scope);

        // Create counter with advisory params (method, status)
        const allowed_attributes = [_][]const u8{ "method", "status" };
        const advisory_params = api.metrics.AdvisoryParams{
            .explicit_bucket_boundaries = null,
            .attributes = &allowed_attributes,
        };

        const counter = try meter.createCounter(i64, "test.counter", "Test counter", "requests", advisory_params);

        const ctx = &[_]api.ContextKeyValue{};

        // Record with attributes
        const all_attributes = [_]api.AttributeKeyValue{
            .{ .key = "method", .value = .{ .string = "GET" } },
            .{ .key = "status", .value = .{ .int = 200 } },
            .{ .key = "user_id", .value = .{ .string = "12345" } },
        };

        counter.add(ctx, 20, &all_attributes);

        // Force collection
        reader.collect();

        // Verify view took precedence over advisory params
        var buffer: [1]sdk.MetricData = undefined;
        const matches = mock_exporter.getMetricsNamed(&buffer, "test.counter");
        try testing.expectEqual(@as(usize, 1), matches.len);

        const metric = matches[0];
        try testing.expect(metric.data_points.len > 0);

        // Check that only view-allowed attributes are present
        const data_point = metric.data_points[0];
        try testing.expectEqual(@as(usize, 1), data_point.attributes.len);

        var found_method = false;
        var found_status = false;
        var found_user_id = false;

        for (data_point.attributes) |attr| {
            if (std.mem.eql(u8, attr.key, "method")) found_method = true;
            if (std.mem.eql(u8, attr.key, "status")) found_status = true;
            if (std.mem.eql(u8, attr.key, "user_id")) found_user_id = true;
        }

        // Only user_id should be present (view overrides advisory)
        try testing.expect(!found_method);
        try testing.expect(!found_status);
        try testing.expect(found_user_id);
    }
}
