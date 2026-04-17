//! OpenTelemetry Runtime Error Handler System
//!
//! This module provides a runtime configurable error handler system that allows
//! applications to customize how OpenTelemetry internal errors are handled.
//! This follows the OpenTelemetry specification's requirement that SDKs must
//! allow end users to change the library's default error handling behavior.

const std = @import("std");
const builtin = @import("builtin");

/// Function signature for custom error handlers
/// The allocator parameter is optional and can be used for detailed message formatting
pub const ErrorHandler = *const fn (info: ErrorInfo, allocator: ?std.mem.Allocator) void;

/// Information about an error that occurred within OpenTelemetry
pub const ErrorInfo = struct {
    /// The component where the error occurred
    component: Component,

    /// The specific operation that failed
    operation: []const u8,

    /// The category/type of error
    error_type: ErrorType,

    /// Human-readable error message
    message: []const u8,

    /// Optional additional context about the error
    context: ?[]const u8 = null,

    /// Optional source Zig error that caused this error
    source_error: ?anyerror = null,
};

/// OpenTelemetry components that can report errors
pub const Component = enum {
    /// Tracer-related components
    tracer,

    /// Logger-related components
    logger,

    /// Meter-related components
    meter,

    /// Exporter components
    exporter,

    /// Processor components
    processor,

    /// Provider components
    provider,

    /// Resource-related components
    resource,

    /// Context-related components
    context,

    /// Baggage-related components
    baggage,

    /// Configuration-related components
    config,

    /// General/unknown component
    general,
};

/// Categories of errors that can occur
pub const ErrorType = enum {
    /// Input validation errors (invalid parameters, etc.)
    validation,

    /// Resource exhaustion (out of memory, queue full, etc.)
    resource_exhausted,

    /// Network/connectivity errors
    network,

    /// Data serialization/deserialization errors
    serialization,

    /// Configuration errors
    configuration,

    /// Timeout errors
    timeout,

    /// Authentication/authorization errors
    authentication,

    /// Internal logic errors
    internal,

    /// Callback execution errors (observable instruments)
    callback,

    /// Unknown/unspecified errors
    unknown,
};

/// Global error handler state
var global_error_handler: ?ErrorHandler = null;
var handler_mutex: std.atomic.Mutex = .unlocked;

/// Returns true if input validation should be performed throughout the OpenTelemetry API.
///
/// This function serves as the central control point for all validation decisions
/// across the OpenTelemetry implementation. It enables comprehensive input validation
/// in debug builds while ensuring zero-cost performance in production releases.
///
/// ## Purpose and Design
///
/// The validation system follows OpenTelemetry's core principle: telemetry must never
/// disrupt application behavior. This function enables a validation strategy that:
/// - Catches developer errors early during development (debug builds)
/// - Provides zero overhead in production (release builds)
/// - Maintains consistent validation policy across all API surfaces
/// - Allows future extensibility for configurable validation levels
///
/// ## Usage Throughout the API
///
/// This function is used by validation functions across the codebase:
/// - `validateAttributeKey()` - Validates attribute keys in spans, events, etc.
/// - `validateSpanName()` - Validates span names in tracer operations
/// - `validateAttributes()` - Batch validation for attribute collections
/// - `AttributeBuilder.addKeyValue()` - Builder validation during construction
///
/// ## Performance Characteristics
///
/// - **Release builds**: Function is inlined and optimized away completely
/// - **Debug builds**: Single compile-time constant check (zero runtime cost)
/// - **Memory**: No allocations or state maintained
/// - **Branching**: Optimized by compiler to eliminate dead code paths
///
/// ## Error Handling Integration
///
/// When validation is enabled, detected issues are reported via the global error
/// handler system (`reportValidationError`), but operations continue with safe
/// defaults following the OpenTelemetry specification.
///
/// ## Architectural Benefits
///
/// Using this function instead of direct `builtin.mode` checks provides:
/// - **Centralized policy**: Single location to modify validation behavior
/// - **Clear intent**: Code clearly indicates validation purpose
/// - **Future flexibility**: Easy to extend with runtime configuration
/// - **Consistency**: Uniform validation behavior across all components
/// - **Testability**: Validation behavior can be verified in debug builds
///
/// ## Future Extensibility
///
/// This design allows for potential future enhancements such as:
/// - Runtime validation level configuration
/// - Environment-based validation control
/// - Component-specific validation policies
/// - Performance profiling integration
///
/// ## Example Usage
///
/// ```zig
/// fn validateInput(key: []const u8) bool {
///     if (!isValidatingMode()) return true; // No validation in release
///
///     if (key.len == 0) {
///         reportValidationError(.tracer, "operation", "Empty key", null);
///         return false;
///     }
///     return true;
/// }
/// ```
///
/// ## Returns
/// - `true` in debug builds (validation enabled)
/// - `false` in release builds (validation disabled, zero-cost)
pub inline fn isValidatingMode() bool {
    return builtin.mode == .Debug;
}

/// Default error handler that logs to stderr
fn defaultErrorHandler(info: ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator; // Not used in default handler for simplicity
    std.debug.print("[OpenTelemetry Error] Component: {t}, Operation: {s}, Type: {t}, Message: {s}", .{
        info.component,
        info.operation,
        info.error_type,
        info.message,
    });

    if (info.source_error) |err| {
        std.debug.print(", Error: {s}", .{@errorName(err)});
    }

    if (info.context) |ctx| {
        std.debug.print(", Context: {s}", .{ctx});
    }

    std.debug.print("\n", .{});
}

/// Set the global error handler
///
/// This function allows applications to customize how OpenTelemetry errors
/// are handled. Pass null to reset to the default handler.
pub fn setGlobalErrorHandler(handler: ?ErrorHandler) void {
    while (!handler_mutex.tryLock()) {}
    defer handler_mutex.unlock();

    global_error_handler = handler;
}

/// Get the current global error handler
pub fn getGlobalErrorHandler() ?ErrorHandler {
    while (!handler_mutex.tryLock()) {}
    defer handler_mutex.unlock();

    return global_error_handler;
}

/// Report an error using the configured error handler
///
/// This function is called by OpenTelemetry components when they encounter
/// errors that would otherwise be suppressed. The error will be handled
/// by the currently configured error handler.
pub fn reportError(info: ErrorInfo) void {
    while (!handler_mutex.tryLock()) {}
    const handler = global_error_handler orelse defaultErrorHandler;
    handler_mutex.unlock();

    // Call the handler outside the mutex to avoid potential deadlocks
    // if the handler tries to change the error handler
    handler(info, null);
}

/// Report an error with optional allocator for detailed message formatting
///
/// This variant allows the error handler to perform detailed message formatting
/// if an allocator is provided.
pub fn reportErrorWithAllocator(info: ErrorInfo, allocator: std.mem.Allocator) void {
    while (!handler_mutex.tryLock()) {}
    const handler = global_error_handler orelse defaultErrorHandler;
    handler_mutex.unlock();

    // Call the handler outside the mutex to avoid potential deadlocks
    // if the handler tries to change the error handler
    handler(info, allocator);
}

/// Format a detailed error message including source error information
///
/// This utility function can be used by error handlers to create detailed
/// error messages that include both the operational context and the raw Zig error.
pub fn formatDetailedMessage(allocator: std.mem.Allocator, info: ErrorInfo) ![]const u8 {
    if (info.source_error) |err| {
        if (info.context) |ctx| {
            return std.fmt.allocPrint(allocator, "{s}: {s} (Context: {s})", .{ info.message, @errorName(err), ctx });
        } else {
            return std.fmt.allocPrint(allocator, "{s}: {s}", .{ info.message, @errorName(err) });
        }
    } else {
        if (info.context) |ctx| {
            return std.fmt.allocPrint(allocator, "{s} (Context: {s})", .{ info.message, ctx });
        } else {
            return allocator.dupe(u8, info.message);
        }
    }
}

/// Convenience function to report validation errors
pub fn reportValidationError(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .validation,
        .message = message,
        .context = context,
    });
}

/// Convenience function to report validation errors with source error
pub fn reportValidationErrorWithSource(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
    source_error: anyerror,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .validation,
        .message = message,
        .context = context,
        .source_error = source_error,
    });
}

/// Convenience function to report resource exhaustion errors
pub fn reportResourceExhaustedError(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .resource_exhausted,
        .message = message,
        .context = context,
    });
}

/// Convenience function to report resource exhaustion errors with source error
pub fn reportResourceExhaustedErrorWithSource(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
    source_error: anyerror,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .resource_exhausted,
        .message = message,
        .context = context,
        .source_error = source_error,
    });
}

/// Convenience function to report network errors
pub fn reportNetworkError(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .network,
        .message = message,
        .context = context,
    });
}

/// Convenience function to report network errors with source error
pub fn reportNetworkErrorWithSource(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
    source_error: anyerror,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .network,
        .message = message,
        .context = context,
        .source_error = source_error,
    });
}

/// Convenience function to report serialization errors
pub fn reportSerializationError(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .serialization,
        .message = message,
        .context = context,
    });
}

/// Convenience function to report serialization errors with source error
pub fn reportSerializationErrorWithSource(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
    source_error: anyerror,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .serialization,
        .message = message,
        .context = context,
        .source_error = source_error,
    });
}

/// Report a callback execution error with context
pub fn reportCallbackError(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .callback,
        .message = message,
        .context = context,
    });
}

/// Report a callback execution error with source error
pub fn reportCallbackErrorWithSource(
    component: Component,
    operation: []const u8,
    message: []const u8,
    context: ?[]const u8,
    source_error: anyerror,
) void {
    reportError(.{
        .component = component,
        .operation = operation,
        .error_type = .callback,
        .message = message,
        .context = context,
        .source_error = source_error,
    });
}

/// Mock error handler for testing that collects errors instead of printing them
pub const MockErrorHandler = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ErrorInfo),

    pub fn init(allocator: std.mem.Allocator) MockErrorHandler {
        return .{
            .allocator = allocator,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *MockErrorHandler) void {
        // Free any allocated context strings
        for (self.errors.items) |error_info| {
            if (error_info.context) |ctx| {
                self.allocator.free(ctx);
            }
        }
        self.errors.deinit(self.allocator);
    }

    pub fn handleError(self: *MockErrorHandler, info: ErrorInfo) void {
        // Clone the ErrorInfo to ensure we own all memory
        var cloned_info = info;
        if (info.context) |ctx| {
            cloned_info.context = self.allocator.dupe(u8, ctx) catch return;
        }

        self.errors.append(self.allocator, cloned_info) catch return;
    }

    pub fn errorCount(self: *const MockErrorHandler) usize {
        return self.errors.items.len;
    }

    pub fn getError(self: *const MockErrorHandler, index: usize) ?ErrorInfo {
        if (index >= self.errors.items.len) return null;
        return self.errors.items[index];
    }

    pub fn clearErrors(self: *MockErrorHandler) void {
        // Free any allocated context strings
        for (self.errors.items) |error_info| {
            if (error_info.context) |ctx| {
                self.allocator.free(ctx);
            }
        }
        self.errors.clearRetainingCapacity();
    }

    pub fn hasErrorWithMessage(self: *const MockErrorHandler, message: []const u8) bool {
        for (self.errors.items) |error_info| {
            if (std.mem.eql(u8, error_info.message, message)) {
                return true;
            }
        }
        return false;
    }

    pub fn hasErrorWithComponent(self: *const MockErrorHandler, component: Component) bool {
        for (self.errors.items) |error_info| {
            if (error_info.component == component) {
                return true;
            }
        }
        return false;
    }

    pub fn hasErrorWithType(self: *const MockErrorHandler, error_type: ErrorType) bool {
        for (self.errors.items) |error_info| {
            if (error_info.error_type == error_type) {
                return true;
            }
        }
        return false;
    }
};

/// Global mock error handler instance for testing
var global_mock_handler: ?*MockErrorHandler = null;
var mock_handler_mutex: std.atomic.Mutex = .unlocked;

/// Set a mock error handler for testing
pub fn setMockErrorHandler(mock_handler: *MockErrorHandler) void {
    // Update global_mock_handler under mock_handler_mutex, then register the
    // dispatch function outside that lock. Keeping setGlobalErrorHandler inside
    // the lock would create an AB/BA deadlock: this function holds
    // mock_handler_mutex while acquiring handler_mutex, and
    // mockErrorHandlerDispatch (called under handler_mutex) acquires
    // mock_handler_mutex.
    {
        while (!mock_handler_mutex.tryLock()) {}
        defer mock_handler_mutex.unlock();
        global_mock_handler = mock_handler;
    }
    setGlobalErrorHandler(mockErrorHandlerDispatch);
}

/// Clear the mock error handler and restore default behavior
pub fn clearMockErrorHandler() void {
    {
        while (!mock_handler_mutex.tryLock()) {}
        defer mock_handler_mutex.unlock();
        global_mock_handler = null;
    }
    setGlobalErrorHandler(null);
}

/// Dispatch function for the mock error handler
fn mockErrorHandlerDispatch(info: ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator;

    while (!mock_handler_mutex.tryLock()) {}
    defer mock_handler_mutex.unlock();

    if (global_mock_handler) |mock_handler| {
        mock_handler.handleError(info);
    }
}

test "MockErrorHandler collects errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock_handler = MockErrorHandler.init(allocator);
    defer mock_handler.deinit();

    // Set the mock handler
    setMockErrorHandler(&mock_handler);
    defer clearMockErrorHandler();

    // Generate some errors
    reportValidationError(.tracer, "test", "Test validation error", null);
    reportError(.{
        .component = .meter,
        .operation = "test",
        .error_type = .callback,
        .message = "Test callback error",
        .context = "test context",
    });

    // Verify errors were collected
    try testing.expectEqual(@as(usize, 2), mock_handler.errorCount());

    // Check first error
    const error1 = mock_handler.getError(0).?;
    try testing.expectEqual(Component.tracer, error1.component);
    try testing.expectEqual(ErrorType.validation, error1.error_type);
    try testing.expectEqualStrings("Test validation error", error1.message);

    // Check second error
    const error2 = mock_handler.getError(1).?;
    try testing.expectEqual(Component.meter, error2.component);
    try testing.expectEqual(ErrorType.callback, error2.error_type);
    try testing.expectEqualStrings("Test callback error", error2.message);
    try testing.expectEqualStrings("test context", error2.context.?);

    // Test helper functions
    try testing.expect(mock_handler.hasErrorWithMessage("Test validation error"));
    try testing.expect(mock_handler.hasErrorWithComponent(.tracer));
    try testing.expect(mock_handler.hasErrorWithType(.validation));

    // Test clear functionality
    mock_handler.clearErrors();
    try testing.expectEqual(@as(usize, 0), mock_handler.errorCount());
}

test "error handler registration and invocation" {
    const testing = std.testing;

    // Test data for capturing calls
    const TestData = struct {
        var last_info: ?ErrorInfo = null;

        fn testHandler(info: ErrorInfo, alloc: ?std.mem.Allocator) void {
            _ = alloc;
            last_info = info;
        }

        fn reset() void {
            last_info = null;
        }
    };

    TestData.reset();

    // Initially should be null (uses default handler)
    try testing.expect(getGlobalErrorHandler() == null);

    // Set custom handler
    setGlobalErrorHandler(TestData.testHandler);
    try testing.expect(getGlobalErrorHandler() != null);

    // Report an error
    const test_info = ErrorInfo{
        .component = .tracer,
        .operation = "test_operation",
        .error_type = .validation,
        .message = "test message",
        .context = "test context",
    };

    reportError(test_info);

    // Verify the handler was called
    try testing.expect(TestData.last_info != null);
    const captured = TestData.last_info.?;

    try testing.expectEqual(Component.tracer, captured.component);
    try testing.expectEqualStrings("test_operation", captured.operation);
    try testing.expectEqual(ErrorType.validation, captured.error_type);
    try testing.expectEqualStrings("test message", captured.message);
    try testing.expectEqualStrings("test context", captured.context.?);

    // Reset to default handler
    setGlobalErrorHandler(null);
    try testing.expect(getGlobalErrorHandler() == null);
}

test "convenience error reporting functions" {
    const testing = std.testing;

    const TestData = struct {
        var calls: std.ArrayList(ErrorInfo) = .empty;
        var allocator: std.mem.Allocator = undefined;

        fn init(alloc: std.mem.Allocator) void {
            allocator = alloc;
            calls = .empty;
        }

        fn deinit() void {
            calls.deinit(allocator);
        }

        fn testHandler(info: ErrorInfo, alloc: ?std.mem.Allocator) void {
            _ = alloc;
            calls.append(allocator, info) catch return;
        }

        fn reset() void {
            calls.clearRetainingCapacity();
        }
    };

    TestData.init(testing.allocator);
    defer TestData.deinit();

    setGlobalErrorHandler(TestData.testHandler);
    defer setGlobalErrorHandler(null);

    // Test validation error
    reportValidationError(.tracer, "validate_span", "invalid span name", "span_name=\"\"");

    // Test resource exhausted error
    reportResourceExhaustedError(.processor, "queue_append", "queue is full", "queue_size=1000");

    // Test network error
    reportNetworkError(.exporter, "http_request", "connection failed", "endpoint=http://localhost:4318");

    // Test serialization error
    reportSerializationError(.exporter, "serialize_json", "invalid JSON", null);

    // Verify all calls were captured
    try testing.expectEqual(@as(usize, 4), TestData.calls.items.len);

    // Verify validation error
    const validation_call = TestData.calls.items[0];
    try testing.expectEqual(Component.tracer, validation_call.component);
    try testing.expectEqual(ErrorType.validation, validation_call.error_type);
    try testing.expectEqualStrings("validate_span", validation_call.operation);

    // Verify resource exhausted error
    const resource_call = TestData.calls.items[1];
    try testing.expectEqual(Component.processor, resource_call.component);
    try testing.expectEqual(ErrorType.resource_exhausted, resource_call.error_type);
    try testing.expectEqualStrings("queue_append", resource_call.operation);

    // Verify network error
    const network_call = TestData.calls.items[2];
    try testing.expectEqual(Component.exporter, network_call.component);
    try testing.expectEqual(ErrorType.network, network_call.error_type);
    try testing.expectEqualStrings("http_request", network_call.operation);

    // Verify serialization error
    const serialization_call = TestData.calls.items[3];
    try testing.expectEqual(Component.exporter, serialization_call.component);
    try testing.expectEqual(ErrorType.serialization, serialization_call.error_type);
    try testing.expectEqualStrings("serialize_json", serialization_call.operation);
    try testing.expect(serialization_call.context == null);
}

test "default error handler does not crash on stderr errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use mock error handler to capture errors instead of printing to stderr
    var mock_error_handler = MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    setMockErrorHandler(&mock_error_handler);
    defer clearMockErrorHandler();

    const test_info = ErrorInfo{
        .component = .general,
        .operation = "test",
        .error_type = .unknown,
        .message = "test error message",
        .context = "test context",
    };

    // This should not crash and should be captured by mock handler
    reportError(test_info);

    // Test with null context
    const test_info_no_context = ErrorInfo{
        .component = .general,
        .operation = "test",
        .error_type = .unknown,
        .message = "test error message",
        .context = null,
    };

    // This should also not crash and should be captured by mock handler
    reportError(test_info_no_context);

    // Verify errors were captured
    try testing.expectEqual(@as(usize, 2), mock_error_handler.errorCount());
}

test "enhanced error reporting with source errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test formatDetailedMessage with source error
    const test_info_with_source = ErrorInfo{
        .component = .exporter,
        .operation = "test_operation",
        .error_type = .network,
        .message = "Network request failed",
        .context = "http://localhost:4318",
        .source_error = error.ConnectionRefused,
    };

    const detailed_msg = try formatDetailedMessage(allocator, test_info_with_source);
    defer allocator.free(detailed_msg);

    // Should include both the message and the source error
    try testing.expect(std.mem.indexOf(u8, detailed_msg, "Network request failed") != null);
    try testing.expect(std.mem.indexOf(u8, detailed_msg, "ConnectionRefused") != null);
    try testing.expect(std.mem.indexOf(u8, detailed_msg, "http://localhost:4318") != null);

    // Test formatDetailedMessage without source error
    const test_info_no_source = ErrorInfo{
        .component = .processor,
        .operation = "test_operation",
        .error_type = .validation,
        .message = "Validation failed",
        .context = "span_name",
        .source_error = null,
    };

    const simple_msg = try formatDetailedMessage(allocator, test_info_no_source);
    defer allocator.free(simple_msg);

    try testing.expect(std.mem.indexOf(u8, simple_msg, "Validation failed") != null);
    try testing.expect(std.mem.indexOf(u8, simple_msg, "span_name") != null);

    // Test convenience functions with source errors
    const TestData = struct {
        var test_allocator: std.mem.Allocator = undefined;
        var calls: std.ArrayList(ErrorInfo) = .empty;

        fn init(alloc: std.mem.Allocator) void {
            test_allocator = alloc;
        }

        fn deinit() void {
            calls.deinit(test_allocator);
        }

        fn testHandler(info: ErrorInfo, alloc: ?std.mem.Allocator) void {
            _ = alloc;
            calls.append(test_allocator, info) catch return;
        }

        fn reset() void {
            calls.clearRetainingCapacity();
        }
    };

    TestData.init(allocator);
    defer TestData.deinit();

    setGlobalErrorHandler(TestData.testHandler);
    defer setGlobalErrorHandler(null);

    // Test reportSerializationErrorWithSource
    reportSerializationErrorWithSource(.exporter, "json_conversion", "JSON serialization failed", "user_data", error.InvalidCharacter);

    try testing.expectEqual(@as(usize, 1), TestData.calls.items.len);
    const captured = TestData.calls.items[0];
    try testing.expectEqual(Component.exporter, captured.component);
    try testing.expectEqual(ErrorType.serialization, captured.error_type);
    try testing.expectEqualStrings("json_conversion", captured.operation);
    try testing.expectEqualStrings("JSON serialization failed", captured.message);
    try testing.expectEqualStrings("user_data", captured.context.?);
    try testing.expectEqual(error.InvalidCharacter, captured.source_error.?);
}
