//! OpenTelemetry Context Key Implementation
//!
//! This module provides compile-time generated context keys that offer type safety
//! and zero-runtime-overhead access to context values.

const std = @import("std");
const api = struct {
    const baggage = struct {
        const BaggageKeyValue = @import("../baggage/baggage.zig").BaggageKeyValue;
    };
    const trace = struct {
        const Span = @import("../trace/span.zig").Span;
    };
};

/// Context value types that can be stored in a context.
/// This is a simplified version without span/baggage references.
pub const ContextValue = union(enum) {
    none: void,
    boolean: bool,
    integer: i64,
    unsigned: u64,
    float: f64,
    string: []const u8,
    baggage: []api.baggage.BaggageKeyValue,
    span_context: api.trace.Span.Context,
    byte: u8,

    pub fn initOwned(allocator: std.mem.Allocator, other: ContextValue) !ContextValue {
        return switch (other) {
            .none => .{ .none = {} },
            .boolean => |boolean| .{ .boolean = boolean },
            .integer => |integer| .{ .integer = integer },
            .unsigned => |unsigned| .{ .unsigned = unsigned },
            .float => |float| .{ .float = float },
            .string => |string| .{ .string = try allocator.dupe(u8, string) },
            .baggage => |baggage| .{ .baggage = try api.baggage.BaggageKeyValue.initOwnedSlice(allocator, baggage) },
            .span_context => |span_context| .{ .span_context = .{
                .trace_id = span_context.trace_id,
                .span_id = span_context.span_id,
                .trace_flags = span_context.trace_flags,
                .is_remote = span_context.is_remote,
                .trace_state = if (span_context.trace_state) |ts| try allocator.dupe(u8, ts) else null,
            } },
            .byte => |byte| .{ .byte = byte },
        };
    }

    pub fn deinitOwned(self: ContextValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |string| allocator.free(string),
            .baggage => |baggage| api.baggage.BaggageKeyValue.deinitOwnedSlice(allocator, baggage),
            .span_context => |span_context| span_context.deinit(allocator),
            else => {},
        }
    }

    /// Create a ContextValue from a typed value
    pub fn from(value: anytype) ContextValue {
        const T = @TypeOf(value);
        return switch (T) {
            bool => .{ .boolean = value },
            i64 => .{ .integer = value },
            u64 => .{ .unsigned = value },
            f64 => .{ .float = value },
            []const u8 => .{ .string = value },
            []api.baggage.BaggageKeyValue => .{ .baggage = value },
            api.trace.Span.Context => .{ .span_context = value },
            u8 => .{ .byte = value },
            comptime_int => .{ .integer = @as(i64, value) },
            comptime_float => .{ .float = @as(f64, value) },
            else => @compileError("Unsupported context value type: " ++ @typeName(T) ++
                ". Supported types: bool, i64, u64, f64, []const u8, []BaggageKeyValue, api.trace.Span.Context"),
        };
    }

    /// Check if this value matches the expected type
    pub fn is(self: ContextValue, comptime T: type) bool {
        return switch (T) {
            bool => self == .boolean,
            i64 => self == .integer,
            u64 => self == .unsigned,
            f64 => self == .float,
            []const u8 => self == .string,
            []api.baggage.BaggageKeyValue => self == .baggage,
            api.trace.Span.Context => self == .span_context,
            u8 => self == .byte,
            else => false,
        };
    }

    /// Extract typed value, returns null if type doesn't match
    pub fn as(self: ContextValue, comptime T: type) ?T {
        return switch (T) {
            bool => switch (self) {
                .boolean => |v| v,
                else => null,
            },
            i64 => switch (self) {
                .integer => |v| v,
                else => null,
            },
            u64 => switch (self) {
                .unsigned => |v| v,
                else => null,
            },
            f64 => switch (self) {
                .float => |v| v,
                else => null,
            },
            []const u8 => switch (self) {
                .string => |v| v,
                else => null,
            },
            []api.baggage.BaggageKeyValue => switch (self) {
                .baggage => |v| v,
                else => null,
            },
            api.trace.Span.Context => switch (self) {
                .span_context => |v| v,
                else => null,
            },
            u8 => switch (self) {
                .byte => |v| v,
                else => null,
            },
            else => null,
        };
    }

    /// Format the ContextValue for debugging/logging
    pub fn format(
        self: ContextValue,
        writer: anytype,
    ) !void {
        _ = self;
        _ = writer;
    }
};

/// Generate a compile-time context key with type safety and optimization.
///
/// This function runs at compile time and returns a type that contains
/// all the key information and specialized methods for that specific key.
///
/// Example usage:
/// ```zig
/// const USER_ID_KEY = ContextKey([]const u8, "user.id");
/// const TIMEOUT_KEY = ContextKey(i64, "request.timeout_ms");
/// const DEBUG_KEY = ContextKey(bool, "debug.enabled");
/// ```
pub fn ContextKey(comptime T: type, comptime name: []const u8) type {
    // Compile-time validation
    comptime {
        if (name.len == 0) {
            @compileError("Context key name cannot be empty");
        }

        // Validate supported types
        switch (T) {
            bool, i64, u64, f64, []const u8, []api.baggage.BaggageKeyValue, api.trace.Span.Context, u8 => {},
            else => @compileError("Unsupported context key type: " ++ @typeName(T) ++
                ". Supported types: bool, i64, u64, f64, []const u8, []BaggageKeyValue, api.trace.Span.Context, u8"),
        }
    }

    return struct {
        const Self = @This();

        /// The type of values this key stores
        pub const ValueType = T;

        /// The human-readable name of this key
        pub const key_name = name;

        /// Unique identifier for this key, computed at compile time
        pub const key_id: u64 = blk: {
            // Use FNV-1a hash for deterministic key IDs
            // Include both name and type name to ensure uniqueness
            var hash: u64 = 0xcbf29ce484222325;
            const type_name = @typeName(T);

            // Hash the type name first
            for (type_name) |byte| {
                hash ^= byte;
                hash *%= 0x100000001b3;
            }

            // Then hash the key name
            for (name) |byte| {
                hash ^= byte;
                hash *%= 0x100000001b3;
            }
            break :blk hash;
        };

        /// Create a ContextValue from a typed value for this key
        /// Create a ContextValue from a typed value for this key
        pub fn wrapValue(value: T) ContextValue {
            return switch (T) {
                bool => ContextValue{ .boolean = value },
                i64 => ContextValue{ .integer = value },
                u64 => ContextValue{ .unsigned = value },
                f64 => ContextValue{ .float = value },
                []const u8 => ContextValue{ .string = value },
                []api.baggage.BaggageKeyValue => ContextValue{ .baggage = value },
                api.trace.Span.Context => ContextValue{ .span_context = value },
                u8 => ContextValue{ .byte = value },
                else => unreachable, // Compile-time validation prevents this
            };
        }

        /// Extract the typed value from a ContextValue for this key
        pub fn unwrapValue(ctx_value: ContextValue) ?T {
            return ctx_value.as(T);
        }

        /// Validate that a ContextValue contains the expected type for this key
        pub fn validateValue(ctx_value: ContextValue) bool {
            return ctx_value.is(T);
        }

        /// Create a ContextValue with compile-time type checking
        pub fn createValue(value: T) ContextValue {
            return Self.wrapValue(value);
        }

        /// Format this key for debugging output
        pub fn format(
            self: Self,
            writer: anytype,
        ) !void {
            _ = self;
            return formatContextKey(Self.key_name, Self.key_id, @typeName(T), writer);
        }
    };
}

/// Private helper function for formatting context keys
fn formatContextKey(
    name: []const u8,
    id: u64,
    value_type: []const u8,
    writer: anytype,
) !void {
    try writer.print("ContextKey{{ name=\"{s}\", id=0x{x}, type={s} }}", .{
        name,
        id,
        value_type,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "ContextKey creation and properties" {
    const testing = std.testing;

    // Test different key types
    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");
    const BoolKey = ContextKey(bool, "test.bool");
    const FloatKey = ContextKey(f64, "test.float");
    const UintKey = ContextKey(u64, "test.uint");

    // Test compile-time properties
    try testing.expectEqualStrings("test.string", StringKey.key_name);
    try testing.expectEqualStrings("test.int", IntKey.key_name);
    try testing.expectEqualStrings("test.bool", BoolKey.key_name);

    try testing.expect(StringKey.ValueType == []const u8);
    try testing.expect(IntKey.ValueType == i64);
    try testing.expect(BoolKey.ValueType == bool);
    try testing.expect(FloatKey.ValueType == f64);
    try testing.expect(UintKey.ValueType == u64);

    // Test that different keys have different IDs
    try testing.expect(StringKey.key_id != IntKey.key_id);
    try testing.expect(IntKey.key_id != BoolKey.key_id);
    try testing.expect(BoolKey.key_id != FloatKey.key_id);

    // Test that same key definition produces same ID
    const StringKey2 = ContextKey([]const u8, "test.string");
    try testing.expect(StringKey.key_id == StringKey2.key_id);
}

test "ContextKey value wrapping and unwrapping" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "user.id");
    const IntKey = ContextKey(i64, "request.timeout");
    const BoolKey = ContextKey(bool, "debug.enabled");
    const FloatKey = ContextKey(f64, "cpu.usage");
    const UintKey = ContextKey(u64, "request.count");

    // Test value wrapping
    const string_val = StringKey.wrapValue("user-123");
    const int_val = IntKey.wrapValue(5000);
    const bool_val = BoolKey.wrapValue(true);
    const float_val = FloatKey.wrapValue(0.85);
    const uint_val = UintKey.wrapValue(42);

    try testing.expect(string_val == .string);
    try testing.expect(int_val == .integer);
    try testing.expect(bool_val == .boolean);
    try testing.expect(float_val == .float);
    try testing.expect(uint_val == .unsigned);

    try testing.expectEqualStrings("user-123", string_val.string);
    try testing.expectEqual(@as(i64, 5000), int_val.integer);
    try testing.expectEqual(true, bool_val.boolean);
    try testing.expectEqual(@as(f64, 0.85), float_val.float);
    try testing.expectEqual(@as(u64, 42), uint_val.unsigned);

    // Test value unwrapping
    try testing.expectEqualStrings("user-123", StringKey.unwrapValue(string_val).?);
    try testing.expectEqual(@as(i64, 5000), IntKey.unwrapValue(int_val).?);
    try testing.expectEqual(true, BoolKey.unwrapValue(bool_val).?);
    try testing.expectEqual(@as(f64, 0.85), FloatKey.unwrapValue(float_val).?);
    try testing.expectEqual(@as(u64, 42), UintKey.unwrapValue(uint_val).?);

    // Test wrong type unwrapping returns null
    try testing.expect(StringKey.unwrapValue(int_val) == null);
    try testing.expect(IntKey.unwrapValue(bool_val) == null);
    try testing.expect(BoolKey.unwrapValue(string_val) == null);
}

test "ContextKey value validation" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.key");
    const IntKey = ContextKey(i64, "test.int");

    const test_string: []const u8 = "test";
    const string_val = ContextValue.from(test_string);
    const int_val = ContextValue.from(@as(i64, 42));
    const bool_val = ContextValue.from(true);

    // Test correct type validation
    try testing.expect(StringKey.validateValue(string_val));
    try testing.expect(IntKey.validateValue(int_val));

    // Test incorrect type validation
    try testing.expect(!StringKey.validateValue(int_val));
    try testing.expect(!StringKey.validateValue(bool_val));
    try testing.expect(!IntKey.validateValue(string_val));
    try testing.expect(!IntKey.validateValue(bool_val));
}

test "ContextKey createValue convenience method" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.int");

    const hello_string: []const u8 = "hello";
    const string_val = StringKey.createValue(hello_string);
    const int_val = IntKey.createValue(123);

    try testing.expect(string_val == .string);
    try testing.expect(int_val == .integer);
    try testing.expectEqualStrings("hello", string_val.string);
    try testing.expectEqual(@as(i64, 123), int_val.integer);
}

test "ContextKey formatting" {
    const testing = std.testing;

    const TestKey = ContextKey([]const u8, "debug.test");

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{TestKey{}});

    const result = w.buffered();
    try testing.expect(std.mem.find(u8, result, "debug.test") != null);
    try testing.expect(std.mem.find(u8, result, "[]const u8") != null);
    try testing.expect(std.mem.find(u8, result, "ContextKey{") != null);
}

test "ContextValue from and as methods" {
    const testing = std.testing;

    // Test creating values with from()
    const test_string: []const u8 = "test";
    const string_val = ContextValue.from(test_string);
    const int_val = ContextValue.from(@as(i64, -42));
    const uint_val = ContextValue.from(@as(u64, 42));
    const bool_val = ContextValue.from(true);
    const float_val = ContextValue.from(@as(f64, 3.14));

    // Test extracting values with as()
    try testing.expectEqualStrings("test", string_val.as([]const u8).?);
    try testing.expectEqual(@as(i64, -42), int_val.as(i64).?);
    try testing.expectEqual(@as(u64, 42), uint_val.as(u64).?);
    try testing.expectEqual(true, bool_val.as(bool).?);
    try testing.expectEqual(@as(f64, 3.14), float_val.as(f64).?);

    // Test wrong type extraction returns null
    try testing.expect(string_val.as(i64) == null);
    try testing.expect(int_val.as(bool) == null);
    try testing.expect(bool_val.as([]const u8) == null);
}

test "ContextValue is method" {
    const testing = std.testing;

    const test_string: []const u8 = "test";
    const string_val = ContextValue.from(test_string);
    const int_val = ContextValue.from(@as(i64, 42));
    const bool_val = ContextValue.from(true);

    // Test correct type checking
    try testing.expect(string_val.is([]const u8));
    try testing.expect(int_val.is(i64));
    try testing.expect(bool_val.is(bool));

    // Test incorrect type checking
    try testing.expect(!string_val.is(i64));
    try testing.expect(!int_val.is(bool));
    try testing.expect(!bool_val.is([]const u8));
}

// Test that keys with same name but different types have different IDs
test "ContextKey different types same name" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "same.name");
    const IntKey = ContextKey(i64, "same.name");

    // Different types should produce different key IDs even with same name
    try testing.expect(StringKey.key_id != IntKey.key_id);
}

// Compile-time error tests (these would fail compilation if uncommented)
// test "compile errors" {
//     // Empty key name
//     const EmptyKey = ContextKey([]const u8, "");
//
//     // Unsupported type
//     const BadKey = ContextKey(*u32, "bad.key");
// }
