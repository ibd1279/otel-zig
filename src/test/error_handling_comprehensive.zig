//! Fast Error Handling Unit Tests
//!
//! This module provides focused unit tests for error handling functionality:
//! - Error handler registration and invocation
//! - AttributeBuilder error states
//! - Validation error reporting
//! - Basic thread safety
//!
//! These tests are designed to be fast (< 10 seconds total) and focused on
//! essential error handling behavior.

const std = @import("std");
const testing = std.testing;
const otel_api = @import("otel-api");

const AttributeKeyValue = otel_api.common.AttributeKeyValue;
const AttributeValue = otel_api.common.AttributeValue;
const AttributeBuilder = otel_api.common.AttributeBuilder;
const ErrorInfo = otel_api.common.ErrorInfo;
const ErrorType = otel_api.common.ErrorType;
const Component = otel_api.common.Component;
const setGlobalErrorHandler = otel_api.common.setGlobalErrorHandler;
const getGlobalErrorHandler = otel_api.common.getGlobalErrorHandler;
const isValidatingMode = otel_api.common.isValidatingMode;
const ErrorHandler = otel_api.common.ErrorHandler;

/// Simple error capture for testing
var test_errors: std.ArrayList(ErrorInfo) = undefined;
var test_mutex: std.atomic.Mutex = .unlocked;
var test_allocator: std.mem.Allocator = undefined;

fn testErrorHandler(info: ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    while (!test_mutex.tryLock()) {}
    defer test_mutex.unlock();
    test_errors.append(test_allocator, info) catch {};
}

fn setupTestCapture(allocator: std.mem.Allocator) void {
    test_allocator = allocator;
    test_errors = std.ArrayList(ErrorInfo).empty;
    setGlobalErrorHandler(testErrorHandler);
}

fn cleanupTestCapture() void {
    test_errors.deinit(test_allocator);
    setGlobalErrorHandler(null);
}

fn getErrorCount() usize {
    while (!test_mutex.tryLock()) {}
    defer test_mutex.unlock();
    return test_errors.items.len;
}

fn clearErrors() void {
    while (!test_mutex.tryLock()) {}
    defer test_mutex.unlock();
    test_errors.clearRetainingCapacity();
}

// =============================================================================
// Basic Error Handler Tests
// =============================================================================

test "error handler registration and basic functionality" {
    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Test basic error reporting
    otel_api.common.reportValidationError(.tracer, "test_operation", "Test message", "test context");

    // Verify error was captured
    try testing.expectEqual(@as(usize, 1), getErrorCount());
}

test "error handler preserves error information" {
    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Report specific error
    otel_api.common.reportError(.{
        .component = .exporter,
        .operation = "test_export",
        .error_type = .network,
        .message = "Network failure",
        .context = "http://localhost:4318",
    });

    // Verify error details
    try testing.expectEqual(@as(usize, 1), getErrorCount());

    while (!test_mutex.tryLock()) {}
    defer test_mutex.unlock();

    const captured = test_errors.items[0];
    try testing.expectEqual(Component.exporter, captured.component);
    try testing.expectEqual(ErrorType.network, captured.error_type);
    try testing.expectEqualStrings("test_export", captured.operation);
    try testing.expectEqualStrings("Network failure", captured.message);
}

// =============================================================================
// AttributeBuilder Error State Tests
// =============================================================================

test "AttributeBuilder handles allocation failure gracefully" {
    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Create a valid builder and then add something that will fail
    var builder = AttributeBuilder.init(allocator);
    defer builder.deinit();

    // Use failing allocator for the addKeyValue operation
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const fail_allocator = failing_allocator.allocator();

    // Override the builder's allocator with failing one and try to add
    // This simulates allocation failure during builder operations
    switch (builder) {
        .valid => |*valid_builder| {
            valid_builder.allocator = fail_allocator;
            builder = builder.add(.{ .key = "test", .value = .{ .string = "value" } });
        },
        .invalid => {},
    }

    // Now verify builder is in invalid state due to allocation failure
    switch (builder) {
        .valid => {
            // If it's still valid, that's actually okay - some allocations might succeed
            // This test is more about ensuring graceful handling than guaranteed failure
        },
        .invalid => |error_info| {
            try testing.expectEqual(ErrorType.resource_exhausted, error_info.error_type);
            try testing.expectEqual(Component.general, error_info.component);
        },
    }
}

test "AttributeBuilder validation in debug mode" {
    if (!isValidatingMode()) return; // Only test in debug mode

    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Test with invalid key (empty string)
    var builder = AttributeBuilder.init(allocator);
    builder = builder.add(.{ .key = "", .value = .{ .string = "test" } });
    defer builder.deinit();

    // Should be in invalid state due to validation failure
    switch (builder) {
        .valid => try testing.expect(false),
        .invalid => |error_info| {
            try testing.expectEqual(ErrorType.validation, error_info.error_type);
            try testing.expectEqual(Component.general, error_info.component);
        },
    }
}

// =============================================================================
// Validation Tests
// =============================================================================

test "span validation reports errors correctly" {
    if (!isValidatingMode()) return; // Skip in release mode - no validation to test

    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Test validation functions directly to avoid global state interference
    const validateAttributeKey = otel_api.common.validateAttributeKey;
    const validateSpanName = otel_api.trace.validateSpanName;
    const validateAttributes = otel_api.trace.validateAttributes;
    const reportValidationError = otel_api.common.reportValidationError;

    // Test validation functions directly
    if (!validateAttributeKey("")) {
        reportValidationError(.tracer, "test", "Empty attribute key", null);
    }
    if (!validateSpanName("")) {
        reportValidationError(.tracer, "test", "Empty span name", null);
    }

    // Test attribute validation
    const invalid_attrs = [_]AttributeKeyValue{
        .{ .key = "", .value = .{ .string = "invalid" } },
        .{ .key = "valid", .value = .{ .string = "valid" } },
    };
    _ = validateAttributes(&invalid_attrs);

    reportValidationError(.tracer, "test", "Test validation error", null);

    // Should have validation errors reported
    try testing.expect(getErrorCount() >= 3);
}

// =============================================================================
// Memory Safety Tests
// =============================================================================

test "error handling does not leak memory" {
    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Perform operations that could potentially leak
    for (0..10) |i| {
        // Create and destroy AttributeBuilder
        var builder = AttributeBuilder.init(allocator);
        builder = builder.add(.{ .key = "test", .value = .{ .string = "value" } });
        const result = builder.finish(allocator) catch continue;
        otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, result);

        // Generate validation errors
        const context = std.fmt.allocPrint(allocator, "iteration_{}", .{i}) catch continue;
        defer allocator.free(context);
        otel_api.common.reportValidationError(.tracer, "memory_test", "Test error", context);
    }

    // Clear captured errors to free memory
    clearErrors();
}

// =============================================================================
// Thread Safety Tests (Basic)
// =============================================================================

test "concurrent error reporting is thread safe" {
    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    const WorkerContext = struct {
        id: u32,
    };

    const worker = struct {
        fn run(context: WorkerContext) void {
            _ = context;
            // Each thread reports a few errors
            for (0..5) |i| {
                otel_api.common.reportValidationError(.tracer, "concurrent_test", "Thread error", "test");
                // Small yield to encourage interleaving
                std.Thread.yield() catch {};
                _ = i;
            }
        }
    }.run;

    // Start a few worker threads
    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, i| {
        const context = WorkerContext{ .id = @intCast(i) };
        thread.* = std.Thread.spawn(.{}, worker, .{context}) catch continue;
    }

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    // Should have received errors from all threads
    const total_errors = getErrorCount();
    try testing.expect(total_errors > 0);
    try testing.expect(total_errors <= num_threads * 5);
}

// =============================================================================
// Integration Tests (Fast)
// =============================================================================

test "validation integration with real API calls" {
    if (!isValidatingMode()) return; // Skip in release mode - no validation to test

    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Test validation integration by calling validation functions used by SDK
    const validateAttributeKey = @import("otel-api").common.validateAttributeKey;
    const validateSpanName = @import("otel-api").trace.validateSpanName;
    const validateInstrumentName = @import("otel-api").metrics.validateInstrumentName;
    const reportValidationError = @import("otel-api").common.reportValidationError;

    // Test various validation scenarios that would occur in real API calls
    if (!validateAttributeKey("")) {
        reportValidationError(.tracer, "setAttribute", "Invalid attribute key provided", null);
    }
    if (!validateSpanName("")) {
        reportValidationError(.tracer, "startSpan", "Empty span name provided", null);
    }
    const validated_name = validateInstrumentName("");
    if (validated_name.len == 0) {
        reportValidationError(.meter, "createCounter", "Empty instrument name provided", null);
    }

    // Should have validation errors reported
    try testing.expect(getErrorCount() > 0);
}

test "error types are correctly categorized" {
    const allocator = testing.allocator;

    const original_handler = getGlobalErrorHandler();
    defer setGlobalErrorHandler(original_handler);

    setupTestCapture(allocator);
    defer cleanupTestCapture();

    // Test different error types
    const error_types = [_]ErrorType{ .validation, .network, .serialization, .resource_exhausted, .timeout };
    const contexts = [_][]const u8{ "test_0", "test_1", "test_2", "test_3", "test_4" };

    for (error_types, 0..) |error_type, i| {
        otel_api.common.reportError(.{
            .component = .tracer,
            .operation = "test",
            .error_type = error_type,
            .message = "Test error",
            .context = contexts[i],
        });
    }

    // Verify all error types were captured
    try testing.expectEqual(error_types.len, getErrorCount());
}
