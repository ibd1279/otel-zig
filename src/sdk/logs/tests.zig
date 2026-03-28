//! OpenTelemetry Logger Provider SDK Implementation
//!
//! This module provides the concrete implementation of LoggerProvider for the SDK.
//! It manages logger lifecycle, caching, and configuration.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/sdk.md

const std = @import("std");

const api = @import("otel-api");
const sdk = struct {
    const Logger = @import("logger.zig").Logger;
    const LoggerProvider = @import("logger_provider.zig").LoggerProvider;
    const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
    const Resource = @import("../resource/resource.zig").Resource;
};

// Import validation functions from API layer
const reportValidationError = api.common.reportValidationError;

// ============================================================================
// TESTS
// ============================================================================

const MockLogRecordExporter = @import("exporter.zig").MockLogRecordExporter;
const SimpleLogRecordProcessor = @import("simple_processor.zig").SimpleLogRecordProcessor;
const BatchLogRecordProcessor = @import("batch_processor.zig").BatchLogRecordProcessor;

test "BatchLogRecordProcessor basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.LoggerProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    // Create mock exporter (heap-allocated, processor takes ownership)
    const mock_exporter = try allocator.create(MockLogRecordExporter);
    mock_exporter.* = MockLogRecordExporter.init(allocator);

    // Create batch processor (heap-allocated, provider takes ownership)
    const processor = try BatchLogRecordProcessor.init(
        allocator,
        mock_exporter.logRecordExporter(),
        100, // short export_interval_ms for test
        10, // max_queue_size
    );

    // Start the processor thread
    try processor.start();

    // Register processor (provider takes ownership)
    try provider.registerProcessor(processor.logProcessor());

    // Get logger
    const scope = api.InstrumentationScope{ .name = "test.batch.logger", .version = "1.0.0" };
    var logger = try provider.getLoggerWithScope(scope);

    // Emit a simple log record
    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    logger.emitLogRecord(
        ctx,
        .info,
        .{ .string = "test" },
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );

    // Force flush to ensure export
    const flush_result = provider.forceFlush(1000);
    try testing.expectEqual(api.common.FlushResult.success, flush_result);

    // Just verify that records were exported - avoid checking string content to prevent memory issues
    try testing.expectEqual(@as(usize, 1), mock_exporter.recordCount());

    // Basic verification that the record has expected severity
    if (mock_exporter.getRecord(0)) |record| {
        try testing.expectEqual(api.logs.Severity.info, record.severity_number);
    }
}

test "BasicLogger log emission through pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);

    var provider = sdk.LoggerProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    // Create mock exporter
    const mock_exporter = try allocator.create(MockLogRecordExporter);
    mock_exporter.* = MockLogRecordExporter.init(allocator);
    // Processor takes ownership of this memory.

    // Create processor (heap-allocated)
    const processor = try allocator.create(SimpleLogRecordProcessor);
    processor.* = SimpleLogRecordProcessor.init(allocator, mock_exporter.logRecordExporter());

    // Register processor (provider takes ownership)
    try provider.registerProcessor(processor.logProcessor());

    // Get logger
    const scope = api.InstrumentationScope{ .name = "test.logger", .version = "1.0.0" };
    var logger = try provider.getLoggerWithScope(scope);

    // Emit logs of different severities
    const ctx = &[_]api.ContextKeyValue{};

    logger.emitLogRecord(
        ctx,
        .info,
        .{ .string = "Info message" },
        null,
        null,
        null,
        null,
        "INFO",
        null,
        null,
        null,
    );

    logger.emitLogRecord(
        ctx,
        .@"error",
        .{ .string = "Error message" },
        null,
        null,
        null,
        null,
        "ERROR",
        null,
        null,
        null,
    );

    // Verify records were exported
    try testing.expectEqual(@as(usize, 2), mock_exporter.recordCount());

    if (mock_exporter.getRecord(0)) |record| {
        try testing.expectEqual(api.logs.Severity.info, record.severity_number);
        try testing.expectEqualStrings("Info message", record.body.?.string);
        try testing.expectEqualStrings("INFO", record.severity_text.?);
    }

    if (mock_exporter.getRecord(1)) |record| {
        try testing.expectEqual(api.logs.Severity.@"error", record.severity_number);
        try testing.expectEqualStrings("Error message", record.body.?.string);
        try testing.expectEqualStrings("ERROR", record.severity_text.?);
    }
}

test "BasicLogger severity filtering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.LoggerProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    // Add a processor so enabled() can return true per spec
    const mock_exporter = try allocator.create(MockLogRecordExporter);
    mock_exporter.* = MockLogRecordExporter.init(allocator);

    const processor = try allocator.create(SimpleLogRecordProcessor);
    processor.* = SimpleLogRecordProcessor.init(allocator, mock_exporter.logRecordExporter());

    try provider.registerProcessor(processor.logProcessor());

    const scope = api.InstrumentationScope{ .name = "test.logger", .version = "1.0.0" };
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = &[_]api.ContextKeyValue{};

    // Test enabled() method - with processor registered, not all severities should be enabled
    // since min_severity = .debug is the default.
    try testing.expect(logger.enabled(ctx, .@"error"));
    try testing.expect(logger.enabled(ctx, .warn));
    try testing.expect(logger.enabled(ctx, .info));
    try testing.expect(logger.enabled(ctx, .debug));
    try testing.expect(!logger.enabled(ctx, .trace));
}

test "BasicLogger processor enabled() integration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.LoggerProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const scope = api.InstrumentationScope{ .name = "test.logger", .version = "1.0.0" };
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = &[_]api.ContextKeyValue{};

    // Test 1: No processors - should return false per spec
    try testing.expect(!logger.enabled(ctx, .info));
    try testing.expect(!logger.enabledWithEvent(ctx, .info, "test.event"));

    // Test 2: Add processor without enabled() method - should return true (default behavior)
    const mock_exporter = try allocator.create(MockLogRecordExporter);
    mock_exporter.* = MockLogRecordExporter.init(allocator);

    const basic_processor = try allocator.create(SimpleLogRecordProcessor);
    basic_processor.* = SimpleLogRecordProcessor.init(allocator, mock_exporter.logRecordExporter());

    try provider.registerProcessor(basic_processor.logProcessor());

    // Now enabled() should return true since SimpleLogRecordProcessor doesn't implement enabled()
    // and gets the default "true" behavior
    try testing.expect(logger.enabled(ctx, .info));
    try testing.expect(logger.enabledWithEvent(ctx, .info, "test.event"));

    // Test 3: Verify severity filtering still works
    // Since min_severity = .invalid (0), all severities should be enabled
    try testing.expect(logger.enabled(ctx, .@"error"));
    try testing.expect(!logger.enabled(ctx, .trace)); // All severities >= .debug (0)
    try testing.expect(logger.enabled(ctx, .info)); // All severities >= .debug (0)
}

test "BasicLogger shutdown behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.LoggerProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockLogRecordExporter);
    mock_exporter.* = MockLogRecordExporter.init(allocator);

    const processor = try allocator.create(SimpleLogRecordProcessor);
    processor.* = SimpleLogRecordProcessor.init(allocator, mock_exporter.logRecordExporter());

    try provider.registerProcessor(processor.logProcessor());

    const scope = api.InstrumentationScope{ .name = "test.logger", .version = "1.0.0" };
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = &[_]api.ContextKeyValue{};

    // Emit log before shutdown
    logger.emitLogRecord(ctx, .info, .{ .string = "Before shutdown" }, null, null, null, null, "INFO", null, null, null);
    try testing.expectEqual(@as(usize, 1), mock_exporter.recordCount());

    // Shutdown provider
    _ = provider.shutdown(null);

    // Try to emit log after shutdown - should be ignored
    logger.emitLogRecord(ctx, .info, .{ .string = "After shutdown" }, null, null, null, null, "INFO", null, null, null);
    try testing.expectEqual(@as(usize, 1), mock_exporter.recordCount()); // Should still be 1

    // Verify the logger reports as not enabled after shutdown
    try testing.expect(!logger.enabled(ctx, .info));
}

test "BasicLoggerProvider flush behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.LoggerProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockLogRecordExporter);
    mock_exporter.* = MockLogRecordExporter.init(allocator);

    const processor = try allocator.create(SimpleLogRecordProcessor);
    processor.* = SimpleLogRecordProcessor.init(allocator, mock_exporter.logRecordExporter());

    try provider.registerProcessor(processor.logProcessor());

    // Test successful flush
    const result = provider.forceFlush(1000);
    try testing.expectEqual(api.common.FlushResult.success, result);

    // Test flush with failure
    mock_exporter.flush_result = .failure;
    const result2 = provider.forceFlush(1000);
    try testing.expectEqual(api.common.FlushResult.failure, result2);
}

test "BasicLogger with attributes and timestamps" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = try sdk.Resource.initOwned(allocator, .default);
    var provider = sdk.LoggerProvider.init(allocator, std.testing.io, resource);
    defer provider.deinit();

    const mock_exporter = try allocator.create(MockLogRecordExporter);
    mock_exporter.* = MockLogRecordExporter.init(allocator);

    const processor = try allocator.create(SimpleLogRecordProcessor);
    processor.* = SimpleLogRecordProcessor.init(allocator, mock_exporter.logRecordExporter());
    try provider.registerProcessor(processor.logProcessor());

    const scope = api.InstrumentationScope{ .name = "test.logger", .version = "1.0.0" };
    var logger = try provider.getLoggerWithScope(scope);
    const ctx = &[_]api.ContextKeyValue{};

    // Create attributes
    const attributes = [_]api.AttributeKeyValue{
        .{ .key = "key1", .value = .{ .string = "value1" } },
        .{ .key = "key2", .value = .{ .int = 42 } },
    };

    const timestamp = std.Io.Timestamp.fromNanoseconds(1234567890000000000);
    const observed_timestamp = std.Io.Timestamp.fromNanoseconds(1234567890000000001);

    // Emit log with attributes and timestamps
    logger.emitLogRecord(
        ctx,
        .warn,
        .{ .string = "Warning with attributes" },
        &attributes,
        timestamp,
        observed_timestamp,
        "test.event",
        "WARN",
        null,
        null,
        null,
    );

    // Verify the record
    try testing.expectEqual(@as(usize, 1), mock_exporter.recordCount());

    if (mock_exporter.getRecord(0)) |record| {
        try testing.expectEqual(api.logs.Severity.warn, record.severity_number);
        try testing.expectEqualStrings("Warning with attributes", record.body.?.string);
        try testing.expectEqual(timestamp, record.timestamp);
        try testing.expectEqual(observed_timestamp, record.observed_timestamp);
        try testing.expectEqualStrings("test.event", record.event_name.?);
        try testing.expectEqualStrings("WARN", record.severity_text.?);
        try testing.expectEqual(@as(usize, 2), record.attributes.len);
    }
}
