//! OpenTelemetry Context Implementation
//!
//! This module provides an immutable context for propagating request-scoped values
//! across API boundaries. Context follows explicit Zig idioms with clear ownership
//! and predictable performance characteristics.

const std = @import("std");
const ContextKey = @import("context_key.zig").ContextKey;
const ContextValue = @import("context_key.zig").ContextValue;

/// A key value pair used for context objects.
pub const ContextKeyValue = struct {
    key: u64,
    value: ContextValue,

    pub fn scanSlice(haystack: []const ContextKeyValue, needle: anytype) ?ContextKeyValue {
        // Iterate backwards as the last write is expected to be the value.
        for (0..haystack.len) |i| {
            const idx = haystack.len - 1 - i;
            if (haystack[idx].key == needle.key_id) {
                return haystack[idx];
            }
        }
        return null;
    }

    pub fn initOwned(allocator: std.mem.Allocator, other: ContextKeyValue) !ContextKeyValue {
        return .{
            .key = other.key,
            .value = try .initOwned(allocator, other.value),
        };
    }

    pub fn initOwnedSlice(allocator: std.mem.Allocator, unowned: []const ContextKeyValue) ![]ContextKeyValue {
        var owned = try allocator.alloc(ContextKeyValue, unowned.len);
        errdefer allocator.free(owned);
        var h: usize = 0;
        errdefer for (0..h) |i| owned[i].deinitOwned(allocator);
        while (h < unowned.len) : (h += 1) {
            owned[h] = try initOwned(allocator, unowned[h]);
        }
        return owned;
    }

    pub fn deinitOwned(self: ContextKeyValue, allocator: std.mem.Allocator) void {
        self.value.deinitOwned(allocator);
    }

    pub fn deinitOwnedSlice(allocator: std.mem.Allocator, self: []ContextKeyValue) void {
        for (0..self.len) |h| self[h].deinitOwned(allocator);
        allocator.free(self);
    }

    /// Format the ContextKeyValue for debugging/logging
    pub fn format(
        self: ContextKeyValue,
        writer: anytype,
    ) !void {
        try writer.print("{x}={f}", .{ self.key, self.value });
    }
};

pub const ContextBuilder = @import("../common/builder.zig").Builder(ContextKeyValue);

test "ContextBuilder basic usage" {
    const testing = std.testing;

    const StringKey = ContextKey([]const u8, "test.string");
    const IntKey = ContextKey(i64, "test.i64");

    const result = try ContextBuilder.init(testing.allocator)
        .add(.{ .key = StringKey.key_id, .value = .{ .string = "hello world" } })
        .add(.{ .key = IntKey.key_id, .value = .{ .integer = 2 } })
        .add(.{ .key = StringKey.key_id, .value = .{ .string = "world, hello" } })
        .finish(testing.allocator);
    defer ContextKeyValue.deinitOwnedSlice(testing.allocator, result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(StringKey.key_id, result[0].key);
    try testing.expectEqualStrings("world, hello", result[0].value.string);
    try testing.expectEqual(IntKey.key_id, result[1].key);
    try testing.expectEqual(@as(i64, 2), result[1].value.integer);
}
