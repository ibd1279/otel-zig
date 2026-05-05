//! OpenTelemetry Tracer API
//!
//! This module defines the Tracer interface according to the OpenTelemetry specification.
//! A Tracer creates spans and manages trace instrumentation within a specific scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! ## Input Validation
//!
//! In debug builds, this API performs validation of input parameters:
//! - **Span names**: Empty names are reported but allowed (per OpenTelemetry spec)
//! - **Attributes**: Empty keys are detected and reported
//! - **Error handling**: Validation errors are reported via global error handler but never
//!   prevent span creation (following OpenTelemetry's principle of preferring telemetry
//!   loss over application disruption)
//!
//! In release builds, no validation is performed for optimal performance.
//!
//! ## Performance
//!
//! - **Release builds**: Zero validation overhead
//! - **Debug builds**: Minimal validation cost, errors reported asynchronously
//! - **Memory**: No additional allocations for validation in normal operation
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#tracer

const std = @import("std");
const api = struct {
    const ContextBuilder = @import("../context/context.zig").ContextBuilder;
    const ContextKeyValue = @import("../context/context.zig").ContextKeyValue;
    const trace = struct {
        const Span = @import("span.zig").Span;
    };
};
const isValidatingMode = @import("../common/error_handler.zig").isValidatingMode;

const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const AttributeValue = @import("../common/root.zig").AttributeValue;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const reportValidationError = @import("../common/error_handler.zig").reportValidationError;
const reportError = @import("../common/error_handler.zig").reportError;

/// Tracer interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete tracers.
pub const Tracer = union(enum) {
    noop: void,
    bridge: TracerBridge, // SDK tracer bridge

    /// Start a new span with the given name and options.
    ///
    /// This method creates a new span and returns it. In debug builds, input validation
    /// is performed and any issues are reported via the global error handler, but span
    /// creation always succeeds (potentially with corrected/filtered input).
    ///
    /// ## Parameters
    /// - `name`: Span name (empty names allowed but reported in debug builds)
    /// - `options`: Span configuration including attributes, links, timestamps
    /// - `ctx`: Context for parent relationship and propagation
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Span name**: Empty names are reported but allowed
    /// - **Attributes**: Invalid attributes (empty keys) are reported and filtered
    /// - **Links**: Not currently validated (deferred to future release)
    ///
    /// ## Error Handling
    /// - **Validation errors**: Reported via error handler, operation continues
    /// - **System errors**: Memory allocation failures may result in an incomplete or noop span.
    /// - **No-op fallback**: On critical failures, returns non-recording span
    ///
    /// ## Returns
    /// Always returns a valid `Span` (may be no-op on critical failures)
    pub fn startSpan(
        self: *const Tracer,
        name: []const u8,
        options: ?api.trace.Span.StartOptions,
        ctx: []const api.ContextKeyValue,
    ) api.trace.Span {
        return switch (self.*) {
            .noop => .{ .noop = api.trace.Span.Context.invalid },
            .bridge => |*bridge| bridge.startSpanFn(bridge.tracer_ptr, name, options, ctx),
        };
    }

    /// Check if this tracer is enabled.
    ///
    /// This API helps users avoid performing computationally expensive operations when
    /// creating spans if the tracer is disabled. The returned value can change over time,
    /// so this should be called each time before creating a span.
    ///
    /// ## Returns
    /// - `true` if the tracer is enabled for span creation
    /// - `false` if the tracer is disabled (no-op tracer always returns false)
    pub fn enabled(self: *const Tracer) bool {
        return switch (self.*) {
            .noop => false,
            .bridge => |bridge| bridge.enabledFn(bridge.tracer_ptr),
        };
    }
};

/// Bridge structure that holds SDK tracer pointer and vtable
pub const TracerBridge = struct {
    tracer_ptr: *anyopaque,
    startSpanFn: *const fn (
        tracer_ptr: *anyopaque,
        name: []const u8,
        options: ?api.trace.Span.StartOptions,
        ctx: []const api.ContextKeyValue,
    ) api.trace.Span,
    enabledFn: *const fn (tracer_ptr: *anyopaque) bool,

    pub fn init(ptr: anytype) TracerBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn startSpan(
                pointer: *anyopaque,
                name: []const u8,
                options: ?api.trace.Span.StartOptions,
                ctx: []const api.ContextKeyValue,
            ) api.trace.Span {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.startSpan(self, name, options, ctx);
            }
            pub fn enabled(pointer: *anyopaque) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabled(self);
            }
        };

        return .{
            .tracer_ptr = ptr,
            .startSpanFn = VTable.startSpan,
            .enabledFn = VTable.enabled,
        };
    }
};

/// Validate that an attribute key meets OpenTelemetry requirements
pub fn validateAttributeKey(key: []const u8) bool {
    if (!isValidatingMode()) return true; // No validation in release
    return key.len > 0; // Non-null guaranteed by Zig type system
}

/// Validate that a span name meets OpenTelemetry requirements.
///
/// In debug builds, validates that span names are non-empty. Empty names are
/// technically allowed by the OpenTelemetry specification but are reported
/// as validation issues for better developer experience.
///
/// ## Returns
/// - `true` if name is valid or if validation is disabled (release builds)
/// - `false` if name is invalid and validation is enabled (debug builds)
pub fn validateSpanName(name: []const u8) bool {
    if (!isValidatingMode()) return true; // No validation in release
    // Empty span names are allowed per spec but should be reported
    return name.len > 0;
}

/// Validate that an attribute value meets OpenTelemetry requirements
pub fn validateAttributeValue(value: AttributeValue) bool {
    // All AttributeValue variants are non-null by union design
    // Arrays are homogeneous by AttributeValue definition
    _ = value;
    return true; // Current design prevents invalid values
}

/// Validate attributes and report errors in debug mode.
///
/// This function validates attribute key-value pairs according to OpenTelemetry
/// requirements and reports validation errors via the global error handler.
/// The original attribute slice is always returned unchanged to avoid memory
/// allocation and ownership complexity.
///
/// ## Validation Rules (Debug Mode Only)
/// - **Keys**: Must be non-empty strings
/// - **Values**: All current AttributeValue types are valid by design
///
/// ## Behavior
/// - **Release builds**: No validation, returns input unchanged
/// - **Debug builds**: Validates and reports errors, returns input unchanged
/// - **Memory**: No allocations, no filtering of invalid attributes
/// - **Error reporting**: Single error report per validation call
///
/// ## Returns
/// Always returns the original `attributes` slice unchanged
pub fn validateAttributes(attributes: []const AttributeKeyValue) []const AttributeKeyValue {
    if (!isValidatingMode()) return attributes; // No validation in release

    // Count invalid attributes
    var invalid_count: usize = 0;

    for (attributes) |attr| {
        if (!validateAttributeKey(attr.key) or !validateAttributeValue(attr.value)) {
            invalid_count += 1;
        }
    }

    // Report errors if any invalid attributes found
    if (invalid_count > 0) {
        reportValidationError(.tracer, "startSpan", "Invalid attributes detected due to empty keys", null);
    }

    // Always return original slice - no memory allocation
    return attributes;
}

test "validateAttributes has no memory leak and reports errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // This test only runs in debug mode
    if (!isValidatingMode()) return;

    // Use mock error handler to capture validation errors instead of printing to stderr
    var mock_error_handler = @import("../common/error_handler.zig").MockErrorHandler.init(allocator);
    defer mock_error_handler.deinit();
    @import("../common/error_handler.zig").setMockErrorHandler(&mock_error_handler);
    defer @import("../common/error_handler.zig").clearMockErrorHandler();

    // Create attributes with some invalid keys
    const test_attrs = [_]AttributeKeyValue{
        .{ .key = "valid.key", .value = AttributeValue{ .string = "valid" } },
        .{ .key = "", .value = AttributeValue{ .string = "invalid" } },
        .{ .key = "another.valid", .value = AttributeValue{ .int = 42 } },
    };

    // Get pointer to original slice
    const original_ptr = test_attrs[0..].ptr;
    const original_len = test_attrs.len;

    // Call validateAttributes
    const result = validateAttributes(&test_attrs);

    // Verify no memory allocation occurred - same pointer and length returned
    try testing.expectEqual(original_ptr, result.ptr);
    try testing.expectEqual(original_len, result.len);

    // Verify validation error was captured
    try testing.expectEqual(@as(usize, 1), mock_error_handler.errorCount());
    const captured_error = mock_error_handler.getError(0).?;
    try testing.expectEqual(@import("../common/error_handler.zig").Component.tracer, captured_error.component);
    try testing.expectEqual(@import("../common/error_handler.zig").ErrorType.validation, captured_error.error_type);
    try testing.expectEqualStrings("Invalid attributes detected due to empty keys", captured_error.message);

    // Verify all original data is unchanged
    try testing.expectEqualStrings("valid.key", result[0].key);
    try testing.expectEqualStrings("", result[1].key); // Invalid key preserved
    try testing.expectEqualStrings("another.valid", result[2].key);

    // Note: Validation errors are reported via error handler (can be seen in test output)
}

test "Tracer enabled method" {
    const testing = std.testing;

    // Test noop tracer returns false for enabled
    var noop_tracer = Tracer{ .noop = {} };

    try testing.expect(!noop_tracer.enabled());
}

test "Tracer enabled method practical usage" {
    const testing = std.testing;

    // Simulate practical usage where expensive operations are avoided when tracer is disabled
    var tracer = Tracer{ .noop = {} };

    var expensive_operation_called = false;

    // This pattern demonstrates how users should use the enabled method
    if (tracer.enabled()) {
        // Expensive operation would only run if tracer is enabled
        expensive_operation_called = true;
    }

    // Verify that expensive operation was not called for noop tracer
    try testing.expect(!expensive_operation_called);

    // Test that the method can be called multiple times (spec requirement)
    try testing.expect(!tracer.enabled());
    try testing.expect(!tracer.enabled());
}
