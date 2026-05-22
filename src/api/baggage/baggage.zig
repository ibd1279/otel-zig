//! OpenTelemetry Baggage API Implementation
//!
//! This module provides the baggage API types according to the OpenTelemetry specification.
//! Baggage is an immutable container for string key-value pairs that propagate across
//! process boundaries.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/baggage/api.md

const std = @import("std");

/// A single baggage entry consisting of a key-value pair and optional metadata
pub const BaggageKeyValue = struct {
    /// The baggage key
    key: []const u8,

    /// The baggage value
    value: []const u8,

    /// Optional metadata
    metadata: ?[]const u8 = null,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
        metadata: ?[]const u8,
    ) !BaggageKeyValue {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        const owned_metadata = if (metadata) |md| try allocator.dupe(u8, md) else null;
        errdefer if (owned_metadata) |md| allocator.free(md);

        return .{ .key = owned_key, .value = owned_value, .metadata = owned_metadata };
    }

    pub fn initOwnedSlice(allocator: std.mem.Allocator, unowned: []BaggageKeyValue) ![]BaggageKeyValue {
        var owned = try allocator.alloc(BaggageKeyValue, unowned.len);
        errdefer allocator.free(owned);
        var h: usize = 0;
        errdefer for (0..h) |i| owned[i].deinitOwned(allocator);
        while (h < unowned.len) : (h += 1) {
            owned[h] = try initOwned(allocator, unowned[h].key, unowned[h].value, unowned[h].metadata);
        }
        return owned;
    }

    pub fn deinitOwned(self: BaggageKeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        if (self.metadata) |metadata| {
            allocator.free(metadata);
        }
    }

    /// Destroy a deep copied slice of BaggageKeyValue.
    pub fn deinitOwnedSlice(allocator: std.mem.Allocator, slice: []const BaggageKeyValue) void {
        for (0..slice.len) |h| slice[h].deinitOwned(allocator);
        allocator.free(slice);
    }

    /// Check if two entries are equal
    pub fn eql(self: BaggageKeyValue, other: BaggageKeyValue) bool {
        if (!std.mem.eql(u8, self.key, other.key)) return false;
        if (!std.mem.eql(u8, self.value, other.value)) return false;

        // Compare metadata
        // TODO decide if metadata should really be part of the
        // baggage equality.
        if (self.metadata == null and other.metadata == null) return true;
        if (self.metadata == null or other.metadata == null) return false;

        return true;
    }

    /// Format the entry for debugging/display
    pub fn format(
        self: BaggageKeyValue,
        writer: anytype,
    ) !void {
        try writer.print("{s}={s}", .{ self.key, self.value });
        if (self.metadata) |meta| {
            try writer.print("{s}", .{meta});
        }
    }
};

/// BaggageBuilder provides a functional interface for constructing arrays of BaggageKeyValue
pub const BaggageBuilder = @import("../common/builder.zig").Builder(BaggageKeyValue);

test "BaggageBuilder basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test empty builder
    const empty_entries = try BaggageBuilder.init(allocator).finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, empty_entries);

    try testing.expectEqual(@as(usize, 0), empty_entries.len);

    // Test single entry
    const single_entries = try BaggageBuilder.init(allocator)
        .add(.{ .key = "user.id", .value = "12345" })
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, single_entries);

    try testing.expectEqual(@as(usize, 1), single_entries.len);
    try testing.expectEqualStrings("user.id", single_entries[0].key);
    try testing.expectEqualStrings("12345", single_entries[0].value);
}

test "BaggageBuilder functional chaining" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entries = try BaggageBuilder.init(allocator)
        .add(.{ .key = "key1", .value = "value1" })
        .add(.{ .key = "key2", .value = "value2", .metadata = "metadata" })
        .add(.{ .key = "key1", .value = "duplicate_value" }) // duplicate key, should use last-wins
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("key1", entries[0].key);
    try testing.expectEqualStrings("duplicate_value", entries[0].value); // last-wins value
    try testing.expectEqualStrings("key2", entries[1].key);
    try testing.expectEqualStrings("value2", entries[1].value);
}

test "BaggageBuilder duplicate key handling - last wins" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entries = try BaggageBuilder.init(allocator)
        .add(.{ .key = "user.id", .value = "first-value" })
        .add(.{ .key = "session.id", .value = "sess-123" })
        .add(.{ .key = "user.id", .value = "last-value" }) // should win
        .add(.{ .key = "trace.id", .value = "trace-456" })
        .add(.{ .key = "session.id", .value = "sess-789" }) // should win
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 3), entries.len);

    // Find each entry and verify last-wins behavior
    var found_user = false;
    var found_session = false;
    var found_trace = false;

    for (entries) |kv| {
        if (std.mem.eql(u8, kv.key, "user.id")) {
            try testing.expectEqualStrings("last-value", kv.value);
            found_user = true;
        } else if (std.mem.eql(u8, kv.key, "session.id")) {
            try testing.expectEqualStrings("sess-789", kv.value);
            found_session = true;
        } else if (std.mem.eql(u8, kv.key, "trace.id")) {
            try testing.expectEqualStrings("trace-456", kv.value);
            found_trace = true;
        }
    }

    try testing.expect(found_user);
    try testing.expect(found_session);
    try testing.expect(found_trace);
}

test "BaggageBuilder duplicate key handling - no duplicates unchanged" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entries = try BaggageBuilder.init(allocator)
        .add(.{ .key = "user.id", .value = "12345" })
        .add(.{ .key = "session.id", .value = "sess-123" })
        .add(.{ .key = "trace.id", .value = "trace-456" })
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 3), entries.len);

    // Should preserve original order and values
    try testing.expectEqualStrings("user.id", entries[0].key);
    try testing.expectEqualStrings("12345", entries[0].value);
    try testing.expectEqualStrings("session.id", entries[1].key);
    try testing.expectEqualStrings("sess-123", entries[1].value);
    try testing.expectEqualStrings("trace.id", entries[2].key);
    try testing.expectEqualStrings("trace-456", entries[2].value);
}

test "BaggageBuilder duplicate key handling - all same key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entries = try BaggageBuilder.init(allocator)
        .add(.{ .key = "user.id", .value = "first" })
        .add(.{ .key = "user.id", .value = "second" })
        .add(.{ .key = "user.id", .value = "third" })
        .add(.{ .key = "user.id", .value = "final" })
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("user.id", entries[0].key);
    try testing.expectEqualStrings("final", entries[0].value);
}

test "BaggageBuilder duplicate key handling - with metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entries = try BaggageBuilder.init(allocator)
        .add(.{ .key = "user.id", .value = "first-value", .metadata = "original-metadata" })
        .add(.{ .key = "session.id", .value = "sess-123" })
        .add(.{ .key = "user.id", .value = "last-value", .metadata = "new-metadata" }) // should win including metadata
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);

    // Find user.id and verify it has the last value and metadata
    var found_user = false;
    var found_session = false;

    for (entries) |kv| {
        if (std.mem.eql(u8, kv.key, "user.id")) {
            try testing.expectEqualStrings("last-value", kv.value);
            try testing.expect(kv.metadata != null);
            try testing.expectEqualStrings("new-metadata", kv.metadata.?);
            found_user = true;
        } else if (std.mem.eql(u8, kv.key, "session.id")) {
            try testing.expectEqualStrings("sess-123", kv.value);
            try testing.expect(kv.metadata == null);
            found_session = true;
        }
    }

    try testing.expect(found_user);
    try testing.expect(found_session);
}

test "BaggageBuilder duplicate key handling - order preservation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that order is preserved based on first appearance of each key
    const entries = try BaggageBuilder.init(allocator)
        .add(.{ .key = "first", .value = "1" }) // position 0
        .add(.{ .key = "second", .value = "2" }) // position 1
        .add(.{ .key = "third", .value = "3" }) // position 2
        .add(.{ .key = "second", .value = "2-new" }) // duplicate, should not change order
        .add(.{ .key = "fourth", .value = "4" }) // position 3
        .add(.{ .key = "first", .value = "1-new" }) // duplicate, should not change order
        .finish(allocator);
    defer BaggageKeyValue.deinitOwnedSlice(allocator, entries);

    try testing.expectEqual(@as(usize, 4), entries.len);

    // Should maintain order based on first appearance
    try testing.expectEqualStrings("first", entries[0].key);
    try testing.expectEqualStrings("1-new", entries[0].value); // last value
    try testing.expectEqualStrings("second", entries[1].key);
    try testing.expectEqualStrings("2-new", entries[1].value); // last value
    try testing.expectEqualStrings("third", entries[2].key);
    try testing.expectEqualStrings("3", entries[2].value);
    try testing.expectEqualStrings("fourth", entries[3].key);
    try testing.expectEqualStrings("4", entries[3].value);
}

test "BaggageKeyValue basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test creating and using individual entries
    const entry1 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    const entry2 = BaggageKeyValue{ .key = "session.id", .value = "abcdef", .metadata = "metadata" };

    try testing.expectEqualStrings("user.id", entry1.key);
    try testing.expectEqualStrings("12345", entry1.value);
    try testing.expect(entry1.metadata == null);

    try testing.expectEqualStrings("session.id", entry2.key);
    try testing.expectEqualStrings("abcdef", entry2.value);
    try testing.expectEqualStrings("metadata", entry2.metadata.?);

    // Test owned entries
    const owned_entry = try BaggageKeyValue.initOwned(allocator, "owned.key", "owned.value", "owned.metadata");
    defer owned_entry.deinitOwned(allocator);

    try testing.expectEqualStrings("owned.key", owned_entry.key);
    try testing.expectEqualStrings("owned.value", owned_entry.value);
    try testing.expectEqualStrings("owned.metadata", owned_entry.metadata.?);
}

test "BaggageKeyValue eql method" {
    const testing = std.testing;

    // Test equal entries without metadata
    const entry1 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    const entry2 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    try testing.expect(entry1.eql(entry2));
    try testing.expect(entry2.eql(entry1));

    // Test different keys
    const entry3 = BaggageKeyValue{ .key = "session.id", .value = "12345", .metadata = null };
    try testing.expect(!entry1.eql(entry3));
    try testing.expect(!entry3.eql(entry1));

    // Test different values
    const entry4 = BaggageKeyValue{ .key = "user.id", .value = "54321", .metadata = null };
    try testing.expect(!entry1.eql(entry4));
    try testing.expect(!entry4.eql(entry1));

    // Test both with null metadata
    const entry5 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    const entry6 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    try testing.expect(entry5.eql(entry6));

    // Test one with metadata, one without
    const entry7 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = "some-metadata" };
    const entry8 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    try testing.expect(!entry7.eql(entry8));
    try testing.expect(!entry8.eql(entry7));

    // Test both with metadata (should be true regardless of metadata content based on current implementation)
    const entry9 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = "metadata1" };
    const entry10 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = "metadata2" };
    try testing.expect(entry9.eql(entry10));
    try testing.expect(entry10.eql(entry9));
}

test "BaggageKeyValue format method" {
    const testing = std.testing;
    var buffer = [_]u8{0} ** 60;

    // Test formatting without metadata
    const entry1 = BaggageKeyValue{ .key = "user.id", .value = "12345", .metadata = null };
    const result1 = try std.fmt.bufPrint(&buffer, "{f}", .{entry1});
    try testing.expectEqualStrings("user.id=12345", result1);

    // Test formatting with metadata
    const entry2 = BaggageKeyValue{ .key = "session.id", .value = "abcdef", .metadata = ";priority=high" };
    const result2 = try std.fmt.bufPrint(&buffer, "{f}", .{entry2});
    try testing.expectEqualStrings("session.id=abcdef;priority=high", result2);

    // Test formatting with empty key and value
    const entry3 = BaggageKeyValue{ .key = "", .value = "", .metadata = null };
    const result3 = try std.fmt.bufPrint(&buffer, "{f}", .{entry3});
    try testing.expectEqualStrings("=", result3);

    // Test formatting with empty metadata
    const entry4 = BaggageKeyValue{ .key = "test.key", .value = "test.value", .metadata = "" };
    const result4 = try std.fmt.bufPrint(&buffer, "{f}", .{entry4});
    try testing.expectEqualStrings("test.key=test.value", result4);

    // Test formatting with special characters
    const entry5 = BaggageKeyValue{ .key = "special-key_123", .value = "value with spaces", .metadata = ";attr=value" };
    const result5 = try std.fmt.bufPrint(&buffer, "{f}", .{entry5});
    try testing.expectEqualStrings("special-key_123=value with spaces;attr=value", result5);
}
