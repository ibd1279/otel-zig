//! OpenTelemetry AttributeValue - Non-owning, lightweight attribute values
//!
//! ## Memory Management
//! AttributeValue is NON-OWNING - it only holds references to data.
//! The caller is responsible for ensuring the lifetime of all referenced data.

const std = @import("std");
const ErrorInfo = @import("error_handler.zig").ErrorInfo;
const reportValidationError = @import("error_handler.zig").reportValidationError;
const reportError = @import("error_handler.zig").reportError;
const isValidatingMode = @import("error_handler.zig").isValidatingMode;

/// Non-owning attribute value type.
/// All memory referenced by this type must be managed by the caller.
///
/// Follows OpenTelemetry specification for supported attribute value types:
/// - Primitive types: bool, int64, float64, string
/// - Homogeneous arrays of primitive types
pub const AttributeValue = union(enum) {
    /// Boolean value
    bool: bool,

    /// Signed 64-bit integer
    int: i64,

    /// IEEE 754 double precision floating point
    float: f64,

    /// UTF-8 string slice (non-owning)
    string: []const u8,

    /// Array of boolean values (non-owning)
    bool_array: []const bool,

    /// Array of signed 64-bit integers (non-owning)
    int_array: []const i64,

    /// Array of double precision floats (non-owning)
    float_array: []const f64,

    /// Array of UTF-8 string slices (non-owning)
    string_array: []const []const u8,

    /// Deep copy an AttributeValue. Must call `deinitOwned` on the return instance.
    pub fn initOwned(self: AttributeValue, allocator: std.mem.Allocator) !AttributeValue {
        return switch (self) {
            .bool, .int, .float => self,
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .bool_array => |s| .{ .bool_array = try allocator.dupe(bool, s) },
            .int_array => |s| .{ .int_array = try allocator.dupe(i64, s) },
            .float_array => |s| .{ .float_array = try allocator.dupe(f64, s) },
            .string_array => |arr| blk: {
                var owned_strings = try allocator.alloc([]const u8, arr.len);
                errdefer allocator.free(owned_strings);

                for (arr, 0..) |str, i| {
                    errdefer for (0..i) |h| allocator.free(owned_strings[h]);
                    owned_strings[i] = try allocator.dupe(u8, str);
                }
                break :blk .{ .string_array = owned_strings };
            },
        };
    }

    /// Destroy a deep copied AttributeValue.
    pub fn deinitOwned(self: AttributeValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .bool, .int, .float => {},
            .string => |s| allocator.free(s),
            .bool_array => |s| allocator.free(s),
            .int_array => |s| allocator.free(s),
            .float_array => |s| allocator.free(s),
            .string_array => |s| {
                for (s) |str| allocator.free(str);
                allocator.free(s);
            },
        }
    }

    /// Compare two AttributeValues for equality
    pub fn eql(self: AttributeValue, other: AttributeValue) bool {
        if (@as(std.meta.Tag(AttributeValue), self) != @as(std.meta.Tag(AttributeValue), other)) {
            return false;
        }

        return switch (self) {
            .bool => |a| a == other.bool,
            .int => |a| a == other.int,
            .float => |a| a == other.float,
            .string => |a| std.mem.eql(u8, a, other.string),
            .bool_array => |a| std.mem.eql(bool, a, other.bool_array),
            .int_array => |a| std.mem.eql(i64, a, other.int_array),
            .float_array => |a| std.mem.eql(f64, a, other.float_array),
            .string_array => |a| blk: {
                const b = other.string_array;
                if (a.len != b.len) break :blk false;
                for (a, b) |str_a, str_b| {
                    if (!std.mem.eql(u8, str_a, str_b)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Hash the AttributeValue for use in hash maps
    pub fn hash(self: AttributeValue, hasher: *std.hash.Wyhash) void {
        // Hash the type tag first to distinguish different types
        const tag = @as(u8, @intFromEnum(@as(std.meta.Tag(AttributeValue), self)));
        hasher.update(std.mem.asBytes(&tag));

        switch (self) {
            .bool => |v| hasher.update(std.mem.asBytes(&v)),
            .int => |v| hasher.update(std.mem.asBytes(&v)),
            .float => |v| hasher.update(std.mem.asBytes(&v)),
            .string => |v| hasher.update(v),
            .bool_array => |v| hasher.update(std.mem.sliceAsBytes(v)),
            .int_array => |v| hasher.update(std.mem.sliceAsBytes(v)),
            .float_array => |v| hasher.update(std.mem.sliceAsBytes(v)),
            .string_array => |v| {
                for (v) |str| {
                    hasher.update(str);
                    // Add separator to distinguish ["ab", "c"] from ["a", "bc"]
                    hasher.update(&[_]u8{0});
                }
            },
        }
    }

    /// Format the AttributeValue for debugging/logging
    pub fn format(
        self: AttributeValue,
        writer: anytype,
    ) !void {
        switch (self) {
            .bool => |v| try writer.print("{any}", .{v}),
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |v| try writer.print("\"{s}\"", .{v}),
            .bool_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{any}", .{item});
                }
                try writer.writeAll("]");
            },
            .int_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{item});
                }
                try writer.writeAll("]");
            },
            .float_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{item});
                }
                try writer.writeAll("]");
            },
            .string_array => |v| {
                try writer.writeAll("[");
                for (v, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("\"{s}\"", .{item});
                }
                try writer.writeAll("]");
            },
        }
    }
};

// -----------------------------------------
// Tests
// -----------------------------------------
test "AttributeValue creation and basic operations" {
    const testing = std.testing;

    // Test primitive types
    const bool_val: AttributeValue = .{ .bool = true };
    try testing.expect(bool_val.bool == true);
    try testing.expectEqualStrings("bool", @tagName(bool_val));

    const int_val: AttributeValue = .{ .int = 42 };
    try testing.expect(int_val.int == 42);
    try testing.expectEqualStrings("int", @tagName(int_val));

    const float_val: AttributeValue = .{ .float = 3.14 };
    try testing.expect(float_val.float == 3.14);
    try testing.expectEqualStrings("float", @tagName(float_val));

    const string_val: AttributeValue = .{ .string = "hello" };
    try testing.expectEqualStrings("hello", string_val.string);
    try testing.expectEqualStrings("string", @tagName(string_val));
}

test "AttributeValue equality comparison" {
    const testing = std.testing;

    // Test primitive equality
    try testing.expect((AttributeValue{ .bool = true }).eql(AttributeValue{ .bool = true }));
    try testing.expect(!(AttributeValue{ .bool = true }).eql(AttributeValue{ .bool = false }));

    try testing.expect((AttributeValue{ .int = 42 }).eql(AttributeValue{ .int = 42 }));
    try testing.expect(!(AttributeValue{ .int = 42 }).eql(AttributeValue{ .int = 43 }));

    try testing.expect((AttributeValue{ .float = 3.14 }).eql(AttributeValue{ .float = 3.14 }));
    try testing.expect(!(AttributeValue{ .float = 3.14 }).eql(AttributeValue{ .float = 2.71 }));

    try testing.expect((AttributeValue{ .string = "hello" }).eql(AttributeValue{ .string = "hello" }));
    try testing.expect(!(AttributeValue{ .string = "hello" }).eql(AttributeValue{ .string = "world" }));

    // Test different types are not equal
    try testing.expect(!(AttributeValue{ .bool = true }).eql(AttributeValue{ .int = 1 }));
    try testing.expect(!(AttributeValue{ .string = "42" }).eql(AttributeValue{ .int = 42 }));
}

test "AttributeValue array types" {
    const testing = std.testing;

    const bool_array = [_]bool{ true, false, true };
    const bool_val = AttributeValue{ .bool_array = &bool_array };
    try testing.expectEqualStrings("bool_array", @tagName(bool_val));

    const int_array = [_]i64{ 1, 2, 3 };
    const int_val = AttributeValue{ .int_array = &int_array };
    try testing.expectEqualStrings("int_array", @tagName(int_val));

    const float_array = [_]f64{ 1.1, 2.2, 3.3 };
    const float_val = AttributeValue{ .float_array = &float_array };
    try testing.expectEqualStrings("float_array", @tagName(float_val));

    const strings = [_][]const u8{ "a", "b", "c" };
    const string_array_val = AttributeValue{ .string_array = &strings };
    try testing.expectEqualStrings("string_array", @tagName(string_array_val));
}

test "AttributeValue array equality" {
    const testing = std.testing;

    const bool_array1 = [_]bool{ true, false };
    const bool_array2 = [_]bool{ true, false };
    const bool_array3 = [_]bool{ false, true };

    const val1 = AttributeValue{ .bool_array = &bool_array1 };
    const val2 = AttributeValue{ .bool_array = &bool_array2 };
    const val3 = AttributeValue{ .bool_array = &bool_array3 };

    try testing.expect(val1.eql(val2));
    try testing.expect(!val1.eql(val3));

    const strings1 = [_][]const u8{ "hello", "world" };
    const strings2 = [_][]const u8{ "hello", "world" };
    const strings3 = [_][]const u8{ "hello", "universe" };

    const str_val1 = AttributeValue{ .string_array = &strings1 };
    const str_val2 = AttributeValue{ .string_array = &strings2 };
    const str_val3 = AttributeValue{ .string_array = &strings3 };

    try testing.expect(str_val1.eql(str_val2));
    try testing.expect(!str_val1.eql(str_val3));
}

test "AttributeValue formatting" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    // Test primitive formatting
    const bool_val: AttributeValue = .{ .bool = true };
    const bool_str = try std.fmt.bufPrint(&buf, "{f}", .{bool_val});
    try testing.expectEqualStrings("true", bool_str);

    const int_val: AttributeValue = .{ .int = -42 };
    const int_str = try std.fmt.bufPrint(&buf, "{f}", .{int_val});
    try testing.expectEqualStrings("-42", int_str);

    const float_val: AttributeValue = .{ .float = 3.14159 };
    const float_str = try std.fmt.bufPrint(&buf, "{f}", .{float_val});
    try testing.expectEqualStrings("3.14159", float_str);

    const string_val: AttributeValue = .{ .string = "hello\nworld" };
    const string_str = try std.fmt.bufPrint(&buf, "{f}", .{string_val});
    try testing.expectEqualStrings("\"hello\nworld\"", string_str);

    // Test array formatting
    const int_array = [_]i64{ 1, 2, 3 };
    const array_val = AttributeValue{ .int_array = &int_array };
    const array_str = try std.fmt.bufPrint(&buf, "{f}", .{array_val});
    try testing.expectEqualStrings("[1, 2, 3]", array_str);
}

test "AttributeValue initOwned and deinitOwned - primitive types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test bool (should be copied by value)
    const bool_val = AttributeValue{ .bool = true };
    const owned_bool = try bool_val.initOwned(allocator);
    defer owned_bool.deinitOwned(allocator);
    try testing.expectEqual(true, owned_bool.bool);

    // Test int (should be copied by value)
    const int_val = AttributeValue{ .int = 42 };
    const owned_int = try int_val.initOwned(allocator);
    defer owned_int.deinitOwned(allocator);
    try testing.expectEqual(@as(i64, 42), owned_int.int);

    // Test float (should be copied by value)
    const float_val = AttributeValue{ .float = 3.14 };
    const owned_float = try float_val.initOwned(allocator);
    defer owned_float.deinitOwned(allocator);
    try testing.expectEqual(3.14, owned_float.float);
}

test "AttributeValue initOwned and deinitOwned - string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original_str = "test string";
    const string_val = AttributeValue{ .string = original_str };
    const owned_string = try string_val.initOwned(allocator);
    defer owned_string.deinitOwned(allocator);

    // Should be equal in content
    try testing.expectEqualStrings(original_str, owned_string.string);
    // Should have different memory addresses (deep copy)
    try testing.expect(original_str.ptr != owned_string.string.ptr);
}

test "AttributeValue initOwned and deinitOwned - arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test bool_array
    const bool_array = [_]bool{ true, false, true };
    const bool_array_val = AttributeValue{ .bool_array = &bool_array };
    const owned_bool_array = try bool_array_val.initOwned(allocator);
    defer owned_bool_array.deinitOwned(allocator);

    try testing.expectEqual(@as(usize, 3), owned_bool_array.bool_array.len);
    try testing.expectEqual(true, owned_bool_array.bool_array[0]);
    try testing.expectEqual(false, owned_bool_array.bool_array[1]);
    try testing.expectEqual(true, owned_bool_array.bool_array[2]);
    // Content verification is sufficient - no need to check pointer addresses

    // Test int_array
    const int_array = [_]i64{ 1, 2, 3 };
    const int_array_val = AttributeValue{ .int_array = &int_array };
    const owned_int_array = try int_array_val.initOwned(allocator);
    defer owned_int_array.deinitOwned(allocator);

    try testing.expectEqual(@as(usize, 3), owned_int_array.int_array.len);
    try testing.expectEqual(@as(i64, 1), owned_int_array.int_array[0]);
    try testing.expectEqual(@as(i64, 2), owned_int_array.int_array[1]);
    try testing.expectEqual(@as(i64, 3), owned_int_array.int_array[2]);
    // Content verification is sufficient - no need to check pointer addresses

    // Test float_array
    const float_array = [_]f64{ 1.1, 2.2, 3.3 };
    const float_array_val = AttributeValue{ .float_array = &float_array };
    const owned_float_array = try float_array_val.initOwned(allocator);
    defer owned_float_array.deinitOwned(allocator);

    try testing.expectEqual(@as(usize, 3), owned_float_array.float_array.len);
    try testing.expectEqual(1.1, owned_float_array.float_array[0]);
    try testing.expectEqual(2.2, owned_float_array.float_array[1]);
    try testing.expectEqual(3.3, owned_float_array.float_array[2]);
    // Content verification is sufficient - no need to check pointer addresses
}

test "AttributeValue initOwned and deinitOwned - string_array" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const string_array = [_][]const u8{ "first", "second", "third" };
    const string_array_val = AttributeValue{ .string_array = &string_array };
    const owned_string_array = try string_array_val.initOwned(allocator);
    defer owned_string_array.deinitOwned(allocator);

    try testing.expectEqual(@as(usize, 3), owned_string_array.string_array.len);
    try testing.expectEqualStrings("first", owned_string_array.string_array[0]);
    try testing.expectEqualStrings("second", owned_string_array.string_array[1]);
    try testing.expectEqualStrings("third", owned_string_array.string_array[2]);

    // Content verification is sufficient - the strings are properly cloned
}

test "AttributeValue hash/equality contract" {
    const testing = std.testing;

    // Helper function to get hash
    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Test primitive types
    const bool_val1: AttributeValue = .{ .bool = true };
    const bool_val2: AttributeValue = .{ .bool = true };
    const bool_val3: AttributeValue = .{ .bool = false };

    try testing.expect(bool_val1.eql(bool_val2));
    try testing.expectEqual(getHash(bool_val1), getHash(bool_val2));
    try testing.expect(!bool_val1.eql(bool_val3));
    try testing.expect(getHash(bool_val1) != getHash(bool_val3));

    const int_val1: AttributeValue = .{ .int = 42 };
    const int_val2: AttributeValue = .{ .int = 42 };
    const int_val3: AttributeValue = .{ .int = 24 };

    try testing.expect(int_val1.eql(int_val2));
    try testing.expectEqual(getHash(int_val1), getHash(int_val2));
    try testing.expect(!int_val1.eql(int_val3));
    try testing.expect(getHash(int_val1) != getHash(int_val3));

    const float_val1: AttributeValue = .{ .float = 3.14 };
    const float_val2: AttributeValue = .{ .float = 3.14 };
    const float_val3: AttributeValue = .{ .float = 2.71 };

    try testing.expect(float_val1.eql(float_val2));
    try testing.expectEqual(getHash(float_val1), getHash(float_val2));
    try testing.expect(!float_val1.eql(float_val3));
    try testing.expect(getHash(float_val1) != getHash(float_val3));

    const str_val1: AttributeValue = .{ .string = "hello" };
    const str_val2: AttributeValue = .{ .string = "hello" };
    const str_val3: AttributeValue = .{ .string = "world" };

    try testing.expect(str_val1.eql(str_val2));
    try testing.expectEqual(getHash(str_val1), getHash(str_val2));
    try testing.expect(!str_val1.eql(str_val3));
    try testing.expect(getHash(str_val1) != getHash(str_val3));
}

test "AttributeValue array hash/equality contract" {
    const testing = std.testing;

    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Test array types
    const bool_arr1 = [_]bool{ true, false, true };
    const bool_arr2 = [_]bool{ true, false, true };
    const bool_arr3 = [_]bool{ false, true, false };

    const bool_val1: AttributeValue = .{ .bool_array = &bool_arr1 };
    const bool_val2: AttributeValue = .{ .bool_array = &bool_arr2 };
    const bool_val3: AttributeValue = .{ .bool_array = &bool_arr3 };

    try testing.expect(bool_val1.eql(bool_val2));
    try testing.expectEqual(getHash(bool_val1), getHash(bool_val2));
    try testing.expect(!bool_val1.eql(bool_val3));
    try testing.expect(getHash(bool_val1) != getHash(bool_val3));

    const int_arr1 = [_]i64{ 1, 2, 3 };
    const int_arr2 = [_]i64{ 1, 2, 3 };
    const int_arr3 = [_]i64{ 3, 2, 1 };

    const int_val1: AttributeValue = .{ .int_array = &int_arr1 };
    const int_val2: AttributeValue = .{ .int_array = &int_arr2 };
    const int_val3: AttributeValue = .{ .int_array = &int_arr3 };

    try testing.expect(int_val1.eql(int_val2));
    try testing.expectEqual(getHash(int_val1), getHash(int_val2));
    try testing.expect(!int_val1.eql(int_val3));
    try testing.expect(getHash(int_val1) != getHash(int_val3));

    const str_arr1 = [_][]const u8{ "a", "b", "c" };
    const str_arr2 = [_][]const u8{ "a", "b", "c" };
    const str_arr3 = [_][]const u8{ "ab", "c" }; // Different splitting, same total content

    const str_val1: AttributeValue = .{ .string_array = &str_arr1 };
    const str_val2: AttributeValue = .{ .string_array = &str_arr2 };
    const str_val3: AttributeValue = .{ .string_array = &str_arr3 };

    try testing.expect(str_val1.eql(str_val2));
    try testing.expectEqual(getHash(str_val1), getHash(str_val2));
    try testing.expect(!str_val1.eql(str_val3));
    try testing.expect(getHash(str_val1) != getHash(str_val3)); // Different due to separator
}

test "AttributeValue different types have different hashes" {
    const testing = std.testing;

    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Same underlying value, different types should have different hashes
    const bool_val: AttributeValue = .{ .bool = true };
    const int_val: AttributeValue = .{ .int = 1 }; // true as int
    const float_val: AttributeValue = .{ .float = 1.0 }; // true/1 as float
    const str_val: AttributeValue = .{ .string = "1" }; // 1 as string

    const bool_hash = getHash(bool_val);
    const int_hash = getHash(int_val);
    const float_hash = getHash(float_val);
    const str_hash = getHash(str_val);

    // All should be different
    try testing.expect(bool_hash != int_hash);
    try testing.expect(bool_hash != float_hash);
    try testing.expect(bool_hash != str_hash);
    try testing.expect(int_hash != float_hash);
    try testing.expect(int_hash != str_hash);
    try testing.expect(float_hash != str_hash);
}

/// A key-value pair used for attributes and other OpenTelemetry contexts.
/// This is a simple non-owning structure that holds references to data.
pub const AttributeKeyValue = struct {
    /// The attribute key (non-owning string slice)
    key: []const u8,

    /// The attribute value (non-owning)
    value: AttributeValue,

    // Scan a slice for a value.
    pub fn scanSlice(haystack: []const AttributeKeyValue, needle: []const u8) ?AttributeKeyValue {
        // Iterate backwards as the last write is expected to be the value.
        for (0..haystack.len) |i| {
            const idx = haystack.len - 1 - i;
            if (std.mem.eql(u8, haystack[idx].key, needle)) {
                return haystack[idx];
            }
        }
        return null;
    }

    /// Deep copy an AttributeKeyValue. Must call `deinitOwned` on the return instance.
    pub fn initOwned(allocator: std.mem.Allocator, key: []const u8, value: AttributeValue) !AttributeKeyValue {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try value.initOwned(allocator);
        return .{
            .key = owned_key,
            .value = owned_value,
        };
    }

    /// Deep copy a slice of AttributeKeyValue.
    pub fn initOwnedSlice(allocator: std.mem.Allocator, unowned: []const AttributeKeyValue) ![]AttributeKeyValue {
        var owned = try allocator.alloc(AttributeKeyValue, unowned.len);
        errdefer allocator.free(owned);
        var h: usize = 0;
        errdefer for (0..h) |i| owned[i].deinitOwned(allocator);
        while (h < unowned.len) : (h += 1) {
            owned[h] = try initOwned(allocator, unowned[h].key, unowned[h].value);
        }
        return owned;
    }

    /// Destroy a deep copied AttributeKeyValue.
    pub fn deinitOwned(self: AttributeKeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.value.deinitOwned(allocator);
    }

    /// Destroy a deep copied slice of AttributeKeyValue.
    pub fn deinitOwnedSlice(allocator: std.mem.Allocator, slice: []const AttributeKeyValue) void {
        for (0..slice.len) |h| slice[h].deinitOwned(allocator);
        allocator.free(slice);
    }

    pub fn validationErrorInfo(self: AttributeKeyValue) ?ErrorInfo {
        if (!validateAttributeKey(self.key)) {
            return .{
                .component = .general,
                .operation = "AttributeKeyValue.key validation",
                .error_type = .validation,
                .message = "Invalid attribute key provided",
                .context = "key must be non-empty",
            };
        }
        return null;
    }

    /// Compare two AttributeKeyValue pairs for equality.
    ///
    /// Equality is defined as a byte comparison on the key and
    /// invoking the equal opretor for the value.
    pub fn eql(self: AttributeKeyValue, other: AttributeKeyValue) bool {
        return std.mem.eql(u8, self.key, other.key) and self.value.eql(other.value);
    }

    /// Hash the AttributeKeyValue for use in hash maps
    pub fn hash(self: AttributeKeyValue, hasher: *std.hash.Wyhash) void {
        hasher.update(self.key);
        self.value.hash(hasher);
    }

    /// Format the AttributeKeyValue for debugging/logging
    pub fn format(
        self: AttributeKeyValue,
        writer: anytype,
    ) !void {
        try writer.print("{s}={f}", .{ self.key, self.value });
    }
};

// -----------------------------------------
// Tests
// -----------------------------------------
test "KeyValue creation and basic operations" {
    const testing = std.testing;

    const kv1 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    try testing.expectEqualStrings("service.name", kv1.key);
    try testing.expectEqualStrings("my-service", kv1.value.string);

    const kv2 = AttributeKeyValue{ .key = "version", .value = .{ .string = "1.0.0" } };
    try testing.expectEqualStrings("version", kv2.key);
    try testing.expectEqualStrings("1.0.0", kv2.value.string);

    const kv3 = AttributeKeyValue{ .key = "port", .value = .{ .int = 8080 } };
    try testing.expectEqualStrings("port", kv3.key);
    try testing.expect(kv3.value.int == 8080);

    const kv4 = AttributeKeyValue{ .key = "debug", .value = .{ .bool = true } };
    try testing.expectEqualStrings("debug", kv4.key);
    try testing.expect(kv4.value.bool == true);

    const kv5 = AttributeKeyValue{ .key = "ratio", .value = .{ .float = 0.95 } };
    try testing.expectEqualStrings("ratio", kv5.key);
    try testing.expect(kv5.value.float == 0.95);
}

test "KeyValue equality comparison" {
    const testing = std.testing;

    const kv1 = AttributeKeyValue{ .key = "name", .value = .{ .string = "test" } };
    const kv2 = AttributeKeyValue{ .key = "name", .value = .{ .string = "test" } };
    const kv3 = AttributeKeyValue{ .key = "name", .value = .{ .string = "different" } };
    const kv4 = AttributeKeyValue{ .key = "different", .value = .{ .string = "test" } };

    try testing.expect(kv1.eql(kv2));
    try testing.expect(!kv1.eql(kv3));
    try testing.expect(!kv1.eql(kv4));
}

test "KeyValue formatting" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    const kv1 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    const str1 = try std.fmt.bufPrint(&buf, "{f}", .{kv1});
    try testing.expectEqualStrings("service.name=\"my-service\"", str1);

    const kv2 = AttributeKeyValue{ .key = "port", .value = .{ .int = 8080 } };
    const str2 = try std.fmt.bufPrint(&buf, "{f}", .{kv2});
    try testing.expectEqualStrings("port=8080", str2);

    const kv3 = AttributeKeyValue{ .key = "enabled", .value = .{ .bool = true } };
    const str3 = try std.fmt.bufPrint(&buf, "{f}", .{kv3});
    try testing.expectEqualStrings("enabled=true", str3);

    // Test key with special characters
    const kv4 = AttributeKeyValue{ .key = "key\nwith\ttabs", .value = .{ .string = "value" } };
    const str4 = try std.fmt.bufPrint(&buf, "{f}", .{kv4});
    try testing.expectEqualStrings("key\nwith\ttabs=\"value\"", str4);
}

test "KeyValue hash/equality contract" {
    const testing = std.testing;

    const getHash = struct {
        fn call(kv: AttributeKeyValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            kv.hash(&hasher);
            return hasher.final();
        }
    }.call;

    const kv1 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    const kv2 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "my-service" } };
    const kv3 = AttributeKeyValue{ .key = "service.name", .value = .{ .string = "other-service" } };
    const kv4 = AttributeKeyValue{ .key = "other.key", .value = .{ .string = "my-service" } };

    // Same key and value should be equal and have same hash
    try testing.expect(kv1.eql(kv2));
    try testing.expectEqual(getHash(kv1), getHash(kv2));

    // Different value should not be equal and should have different hash
    try testing.expect(!kv1.eql(kv3));
    try testing.expect(getHash(kv1) != getHash(kv3));

    // Different key should not be equal and should have different hash
    try testing.expect(!kv1.eql(kv4));
    try testing.expect(getHash(kv1) != getHash(kv4));
}

test "KeyValue Hash consistency" {
    const testing = std.testing;

    const getHash = struct {
        fn call(value: AttributeValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            value.hash(&hasher);
            return hasher.final();
        }
    }.call;

    // Same value should always produce same hash
    const val: AttributeValue = .{ .string = "consistent" };
    const hash1 = getHash(val);
    const hash2 = getHash(val);
    const hash3 = getHash(val);

    try testing.expectEqual(hash1, hash2);
    try testing.expectEqual(hash2, hash3);

    // Same for KeyValue
    const getKvHash = struct {
        fn call(kv: AttributeKeyValue) u64 {
            var hasher = std.hash.Wyhash.init(0);
            kv.hash(&hasher);
            return hasher.final();
        }
    }.call;

    const kv = AttributeKeyValue{ .key = "test.key", .value = .{ .int = 42 } };
    const kv_hash1 = getKvHash(kv);
    const kv_hash2 = getKvHash(kv);
    const kv_hash3 = getKvHash(kv);

    try testing.expectEqual(kv_hash1, kv_hash2);
    try testing.expectEqual(kv_hash2, kv_hash3);
}

/// High-level attribute builder with functional style and automatic memory management.
///
/// The AttributeBuilder provides a fluent interface for constructing attribute collections
/// with built-in validation and error handling. It maintains either a valid state with
/// accumulated attributes or an invalid state with detailed error information.
///
/// ## Usage Pattern
///
/// ```zig
/// var builder = AttributeBuilder.init(temp_allocator);
/// builder = builder.add("service.name", .{ .string = "my-service" })
///                  .add("service.version", .{ .string = "1.0.0" });
/// const attrs = try builder.finish(target_allocator);
/// defer AttributeKeyValue.deinitOwnedSlice(target_allocator, attrs);
/// ```
///
/// ## Error Handling
///
/// - **Valid state**: Normal operation with successful attribute accumulation
/// - **Invalid state**: Contains ErrorInfo with validation or allocation failure details
/// - **Graceful degradation**: Invalid builders return empty arrays from finish()
/// - **Debug reporting**: Errors reported via global error handler in debug builds only
///
/// ## Memory Management
///
/// - **Temporary allocator**: Used during building for intermediate storage
/// - **Target allocator**: Used for final owned result from finish()
/// - **No filtering**: Validation reports errors but doesn't allocate filtered arrays
/// - **Automatic cleanup**: Builder manages its own temporary memory via deinit()
///
/// ## Validation (Debug Mode Only)
///
/// - **Key validation**: Empty keys detected and reported as validation errors
/// - **Value validation**: All AttributeValue variants are valid by design
/// - **Error capture**: Validation failures stored as ErrorInfo with full context
/// - **Continued operation**: Validation errors don't prevent building process
///
/// The builder never takes ownership of any values added to it.
/// Validate that an attribute key meets OpenTelemetry requirements.
///
/// Performs validation according to OpenTelemetry specification in debug builds only.
/// In release builds, always returns true for zero-cost validation.
///
/// ## Validation Rules
/// - **Non-empty**: Keys must have length > 0 (per OpenTelemetry spec)
/// - **Non-null**: Guaranteed by Zig's type system ([]const u8 cannot be null)
/// - **Case sensitivity**: Keys are case-sensitive and preserved exactly
///
/// ## Performance
/// - **Release builds**: Compile-time optimized away (returns true)
/// - **Debug builds**: Single length check (O(1) operation)
/// - **Memory**: No allocations or copies
///
/// ## Returns
/// - `true` if key is valid or validation is disabled (release builds)
/// - `false` if key is invalid and validation is enabled (debug builds)
pub fn validateAttributeKey(key: []const u8) bool {
    if (!isValidatingMode()) return true; // No validation in release
    return key.len > 0; // Non-null guaranteed by Zig type system
}

/// Validate that an attribute value meets OpenTelemetry requirements.
///
/// Currently all AttributeValue variants are valid by design, so this function
/// always returns true. It exists for consistency and future extensibility.
///
/// ## Current Design
/// - **Type safety**: AttributeValue union prevents invalid values at compile time
/// - **Homogeneous arrays**: Array variants enforce type consistency automatically
/// - **Non-null values**: Union design prevents null values
///
/// ## Future Extensibility
/// This function provides a hook for future validation requirements such as:
/// - Value length limits
/// - Array size restrictions
/// - Content validation rules
///
/// ## Performance
/// - **All builds**: Always returns true (optimized away by compiler)
/// - **Memory**: No allocations or processing
///
/// ## Returns
/// Always returns `true` (all current AttributeValue types are valid)
fn validateAttributeValue(value: AttributeValue) bool {
    // All AttributeValue variants are non-null by union design
    // Arrays are homogeneous by AttributeValue definition
    _ = value;
    return true; // Current design prevents invalid values
}

/// Validate attributes and report errors in debug mode, but always return original slice
fn validateAttributes(attributes: []const AttributeKeyValue) []const AttributeKeyValue {
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
        reportValidationError(.tracer, "attribute_validation", "Invalid attributes detected due to empty keys", null);
    }

    // Always return original slice - no memory allocation
    return attributes;
}

pub const AttributeBuilder = @import("builder.zig").Builder(AttributeKeyValue);

// Tests

test "AttributeBuilder resource detection scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate resource detection like DefaultDetector does
    var builder = AttributeBuilder.init(allocator);

    // Add default SDK attributes
    builder = builder.add(.{ .key = "telemetry.sdk.name", .value = .{ .string = "opentelemetry" } });
    builder = builder.add(.{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } });
    builder = builder.add(.{ .key = "telemetry.sdk.version", .value = .{ .string = "0.1.0" } });

    // Add detected environment attributes
    const detected_attrs = [_]AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "my-service" } },
        .{ .key = "process.pid", .value = .{ .int = 1234 } },
    };
    builder = builder.addMany(&detected_attrs);

    const attrs = try builder.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 5), attrs.len);

    // Find and verify SDK attributes
    const sdk_name = AttributeKeyValue.scanSlice(attrs, "telemetry.sdk.name");
    const service_name = AttributeKeyValue.scanSlice(attrs, "service.name");

    try testing.expectEqualStrings("opentelemetry", sdk_name.?.value.string);
    try testing.expectEqualStrings("my-service", service_name.?.value.string);
}

test "AttributeBuilder resource merging scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate Resource.merge() where other resource overrides self resource
    const other_attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "service.name", .value = .{ .string = "new-service" } },
        AttributeKeyValue{ .key = "service.version", .value = .{ .string = "2.0.0" } },
    };

    const self_attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "service.name", .value = .{ .string = "old-service" } },
        AttributeKeyValue{ .key = "host.name", .value = .{ .string = "host1" } },
    };

    // Add other attributes first (they take precedence), then self attributes
    var builder = AttributeBuilder.init(allocator);
    builder = builder.addMany(&other_attrs);
    builder = builder.addMany(&self_attrs);

    const attrs = try builder.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 3), attrs.len);

    // service.name should be "old-service" (last-wins deduplication)
    var service_name: ?AttributeValue = null;
    var host_name: ?AttributeValue = null;
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "service.name")) {
            service_name = attr.value; // Should be the last value added
        } else if (std.mem.eql(u8, attr.key, "host.name")) {
            host_name = attr.value;
        }
    }

    try testing.expectEqualStrings("old-service", service_name.?.string);
    try testing.expectEqualStrings("host1", host_name.?.string);
}

test "AttributeBuilder scope copying scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate provider copying InstrumentationScope attributes
    const original_scope_attrs = [_]AttributeKeyValue{
        AttributeKeyValue{ .key = "instrumentation.name", .value = .{ .string = "test.library" } },
        AttributeKeyValue{ .key = "instrumentation.version", .value = .{ .string = "1.0.0" } },
    };

    const builder = AttributeBuilder.init(allocator);
    const copied_attrs = try builder.addMany(&original_scope_attrs).finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, copied_attrs);

    try testing.expectEqual(@as(usize, 2), copied_attrs.len);

    // Verify the attributes were copied correctly
    var name_found = false;
    var version_found = false;
    for (copied_attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "instrumentation.name")) {
            try testing.expectEqualStrings("test.library", attr.value.string);
            name_found = true;
        } else if (std.mem.eql(u8, attr.key, "instrumentation.version")) {
            try testing.expectEqualStrings("1.0.0", attr.value.string);
            version_found = true;
        }
    }
    try testing.expect(name_found and version_found);
}

test "AttributeBuilder functional chaining pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test the functional immutable pattern used throughout the SDK
    const builder1 = AttributeBuilder.init(allocator);
    const builder2 = builder1.add(.{ .key = "telemetry.sdk.name", .value = .{ .string = "opentelemetry" } });
    const builder3 = builder2.add(.{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } });

    // Each builder is independent - test that builder1 is still empty conceptually
    const empty_attrs = try builder1.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, empty_attrs);
    try testing.expectEqual(@as(usize, 0), empty_attrs.len);

    // And builder3 has the full chain
    const full_attrs = try builder3.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, full_attrs);
    try testing.expectEqual(@as(usize, 2), full_attrs.len);

    // Verify chained attributes
    var sdk_name_found = false;
    var sdk_lang_found = false;
    for (full_attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "telemetry.sdk.name")) {
            try testing.expectEqualStrings("opentelemetry", attr.value.string);
            sdk_name_found = true;
        } else if (std.mem.eql(u8, attr.key, "telemetry.sdk.language")) {
            try testing.expectEqualStrings("zig", attr.value.string);
            sdk_lang_found = true;
        }
    }
    try testing.expect(sdk_name_found and sdk_lang_found);
}

test "AttributeBuilder comprehensive types scenario" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate complex telemetry data with all attribute types
    const feature_flags = [_]bool{ true, false, true };
    const response_codes = [_]i64{ 200, 404, 500 };
    const response_times = [_]f64{ 0.125, 0.250, 1.500 };
    const endpoints = [_][]const u8{ "/api/users", "/api/orders", "/health" };

    var builder = AttributeBuilder.init(allocator);
    builder = builder.add(.{ .key = "service.name", .value = .{ .string = "api-gateway" } });
    builder = builder.add(.{ .key = "service.port", .value = .{ .int = 8080 } });
    builder = builder.add(.{ .key = "debug.enabled", .value = .{ .bool = true } });
    builder = builder.add(.{ .key = "cpu.usage", .value = .{ .float = 0.75 } });
    builder = builder.add(.{ .key = "feature.flags", .value = .{ .bool_array = &feature_flags } });
    builder = builder.add(.{ .key = "http.response_codes", .value = .{ .int_array = &response_codes } });
    builder = builder.add(.{ .key = "response.times", .value = .{ .float_array = &response_times } });
    builder = builder.add(.{ .key = "monitored.endpoints", .value = .{ .string_array = &endpoints } });

    const attrs = try builder.finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 8), attrs.len);

    // Verify specific attributes by type
    var found_count: usize = 0;
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "service.name")) {
            try testing.expectEqualStrings("api-gateway", attr.value.string);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "service.port")) {
            try testing.expectEqual(@as(i64, 8080), attr.value.int);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "debug.enabled")) {
            try testing.expectEqual(true, attr.value.bool);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "cpu.usage")) {
            try testing.expectEqual(@as(f64, 0.75), attr.value.float);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "feature.flags")) {
            try testing.expectEqual(@as(usize, 3), attr.value.bool_array.len);
            try testing.expectEqual(true, attr.value.bool_array[0]);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "http.response_codes")) {
            try testing.expectEqual(@as(usize, 3), attr.value.int_array.len);
            try testing.expectEqual(@as(i64, 200), attr.value.int_array[0]);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "response.times")) {
            try testing.expectEqual(@as(usize, 3), attr.value.float_array.len);
            try testing.expectEqual(@as(f64, 0.125), attr.value.float_array[0]);
            found_count += 1;
        } else if (std.mem.eql(u8, attr.key, "monitored.endpoints")) {
            try testing.expectEqual(@as(usize, 3), attr.value.string_array.len);
            try testing.expectEqualStrings("/api/users", attr.value.string_array[0]);
            found_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 8), found_count);
}

test "AttributeBuilder empty and edge cases" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test empty builder
    const empty_attrs = try AttributeBuilder.init(allocator).finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, empty_attrs);
    try testing.expectEqual(@as(usize, 0), empty_attrs.len);

    // Test adding empty AttributeKeyValue slice
    const empty_kvs: []const AttributeKeyValue = &[_]AttributeKeyValue{};
    const attrs_from_empty = try AttributeBuilder.init(allocator)
        .addMany(empty_kvs)
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs_from_empty);
    try testing.expectEqual(@as(usize, 0), attrs_from_empty.len);

    // Test single attribute
    const single_attr = try AttributeBuilder.init(allocator)
        .add(.{ .key = "single.key", .value = .{ .string = "single.value" } })
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, single_attr);
    try testing.expectEqual(@as(usize, 1), single_attr.len);
    try testing.expectEqualStrings("single.key", single_attr[0].key);
    try testing.expectEqualStrings("single.value", single_attr[0].value.string);
}

test "AttributeBuilder duplicate key handling - last wins" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs = try AttributeBuilder.init(allocator)
        .add(.{ .key = "service.name", .value = .{ .string = "first-value" } })
        .add(.{ .key = "version", .value = .{ .string = "1.0.0" } })
        .add(.{ .key = "service.name", .value = .{ .string = "last-value" } }) // should win
        .add(.{ .key = "environment", .value = .{ .string = "prod" } })
        .add(.{ .key = "version", .value = .{ .string = "2.0.0" } }) // should win
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 3), attrs.len);

    // Find each attribute and verify last-wins behavior
    var found_service = false;
    var found_version = false;
    var found_environment = false;

    for (attrs) |kv| {
        if (std.mem.eql(u8, kv.key, "service.name")) {
            try testing.expectEqualStrings("last-value", kv.value.string);
            found_service = true;
        } else if (std.mem.eql(u8, kv.key, "version")) {
            try testing.expectEqualStrings("2.0.0", kv.value.string);
            found_version = true;
        } else if (std.mem.eql(u8, kv.key, "environment")) {
            try testing.expectEqualStrings("prod", kv.value.string);
            found_environment = true;
        }
    }

    try testing.expect(found_service);
    try testing.expect(found_version);
    try testing.expect(found_environment);
}

test "AttributeBuilder duplicate key handling - no duplicates unchanged" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs = try AttributeBuilder.init(allocator)
        .add(.{ .key = "service.name", .value = .{ .string = "my-service" } })
        .add(.{ .key = "version", .value = .{ .string = "1.0.0" } })
        .add(.{ .key = "environment", .value = .{ .string = "prod" } })
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 3), attrs.len);

    // Should preserve original order and values
    try testing.expectEqualStrings("service.name", attrs[0].key);
    try testing.expectEqualStrings("my-service", attrs[0].value.string);
    try testing.expectEqualStrings("version", attrs[1].key);
    try testing.expectEqualStrings("1.0.0", attrs[1].value.string);
    try testing.expectEqualStrings("environment", attrs[2].key);
    try testing.expectEqualStrings("prod", attrs[2].value.string);
}

test "AttributeBuilder duplicate key handling - all same key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs = try AttributeBuilder.init(allocator)
        .add(.{ .key = "service.name", .value = .{ .string = "first" } })
        .add(.{ .key = "service.name", .value = .{ .string = "second" } })
        .add(.{ .key = "service.name", .value = .{ .string = "third" } })
        .add(.{ .key = "service.name", .value = .{ .string = "final" } })
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expectEqualStrings("service.name", attrs[0].key);
    try testing.expectEqualStrings("final", attrs[0].value.string);
}

test "AttributeBuilder duplicate key handling - different value types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs = try AttributeBuilder.init(allocator)
        .add(.{ .key = "config", .value = .{ .string = "original" } })
        .add(.{ .key = "count", .value = .{ .int = 5 } })
        .add(.{ .key = "config", .value = .{ .int = 42 } }) // different type, should win
        .add(.{ .key = "flag", .value = .{ .bool = false } })
        .add(.{ .key = "count", .value = .{ .string = "ten" } }) // different type, should win
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 3), attrs.len);

    // Find each attribute and verify last-wins with type changes
    var found_config = false;
    var found_count = false;
    var found_flag = false;

    for (attrs) |kv| {
        if (std.mem.eql(u8, kv.key, "config")) {
            try testing.expectEqual(@as(i64, 42), kv.value.int);
            found_config = true;
        } else if (std.mem.eql(u8, kv.key, "count")) {
            try testing.expectEqualStrings("ten", kv.value.string);
            found_count = true;
        } else if (std.mem.eql(u8, kv.key, "flag")) {
            try testing.expectEqual(false, kv.value.bool);
            found_flag = true;
        }
    }

    try testing.expect(found_config);
    try testing.expect(found_count);
    try testing.expect(found_flag);
}

test "AttributeBuilder duplicate key handling - order preservation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that order is preserved based on first appearance of each key
    const attrs = try AttributeBuilder.init(allocator)
        .add(.{ .key = "first", .value = .{ .string = "1" } }) // position 0
        .add(.{ .key = "second", .value = .{ .string = "2" } }) // position 1
        .add(.{ .key = "third", .value = .{ .string = "3" } }) // position 2
        .add(.{ .key = "second", .value = .{ .string = "2-new" } }) // duplicate, should not change order
        .add(.{ .key = "fourth", .value = .{ .string = "4" } }) // position 3
        .add(.{ .key = "first", .value = .{ .string = "1-new" } }) // duplicate, should not change order
        .finish(allocator);
    defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);

    try testing.expectEqual(@as(usize, 4), attrs.len);

    // Should maintain order based on first appearance
    try testing.expectEqualStrings("first", attrs[0].key);
    try testing.expectEqualStrings("1-new", attrs[0].value.string); // last value
    try testing.expectEqualStrings("second", attrs[1].key);
    try testing.expectEqualStrings("2-new", attrs[1].value.string); // last value
    try testing.expectEqualStrings("third", attrs[2].key);
    try testing.expectEqualStrings("3", attrs[2].value.string);
    try testing.expectEqualStrings("fourth", attrs[3].key);
    try testing.expectEqualStrings("4", attrs[3].value.string);
}

test "AttributeBuilder debug mode validation" {
    const testing = std.testing;

    // This test only runs in debug mode
    if (!isValidatingMode()) return;

    const allocator = testing.allocator;

    // Test invalid key (empty string) causes builder to become invalid
    const builder = AttributeBuilder.init(allocator)
        .add(.{ .key = "", .value = .{ .string = "test" } });

    // Builder should be invalid due to empty key
    switch (builder) {
        .valid => try testing.expect(false), // Should not be valid
        .invalid => |error_info| {
            try testing.expectEqual(error_info.component, .general);
            try testing.expectEqual(error_info.error_type, .validation);
            try testing.expectEqualStrings("AttributeKeyValue.key validation", error_info.operation);
            try testing.expectEqualStrings("Invalid attribute key provided", error_info.message);
        },
    }

    // Test that valid keys still work
    const valid_builder = AttributeBuilder.init(allocator)
        .add(.{ .key = "valid.key", .value = .{ .string = "test" } });

    switch (valid_builder) {
        .valid => {
            const attrs = try valid_builder.finish(allocator);
            defer AttributeKeyValue.deinitOwnedSlice(allocator, attrs);
            try testing.expectEqual(@as(usize, 1), attrs.len);
            try testing.expectEqualStrings("valid.key", attrs[0].key);
        },
        .invalid => try testing.expect(false), // Should be valid
    }
}
