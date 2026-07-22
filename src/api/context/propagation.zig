//! OpenTelemetry Context Propagation API
//!
//! This module defines the interfaces for context propagation according to the OpenTelemetry specification.
//! Propagators are used to inject and extract context across process boundaries.
//!
//! The API provides only interfaces and no-op implementations. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/context/api-propagators.md

const std = @import("std");
const api = struct {
    const ContextKeyValue = @import("context.zig").ContextKeyValue;
};
const W3cPropagator = @import("../trace/w3c_propagator.zig").W3cPropagator;
const BaggagePropagator = @import("../baggage/propagator.zig").BaggagePropagator;

/// TextMapCarrier is the interface for carriers used in text map propagation.
/// It provides methods to get, set, and iterate over key-value pairs.
pub const TextMapCarrier = struct {
    /// Get a value for a given key
    getFn: *const fn (self: *const TextMapCarrier, key: []const u8) ?[]const u8,

    /// Set a value for a given key
    setFn: *const fn (self: *TextMapCarrier, key: []const u8, value: []const u8) void,

    /// Get all keys in the carrier
    keysFn: *const fn (self: *const TextMapCarrier, allocator: std.mem.Allocator) anyerror![][]const u8,

    /// Implementation-specific data
    impl: *anyopaque,

    pub fn get(self: *const TextMapCarrier, key: []const u8) ?[]const u8 {
        return self.getFn(self, key);
    }

    pub fn set(self: *TextMapCarrier, key: []const u8, value: []const u8) void {
        self.setFn(self, key, value);
    }

    pub fn keys(self: *const TextMapCarrier, allocator: std.mem.Allocator) ![][]const u8 {
        return self.keysFn(self, allocator);
    }
};

/// TextMapPropagator interface using tagged union for polymorphism
pub const TextMapPropagator = union(enum) {
    noop: void,
    w3c: W3cPropagator,
    baggage: BaggagePropagator,
    composite: []const TextMapPropagator,

    /// Inject context into a carrier
    pub fn inject(self: *const TextMapPropagator, ctx: []api.ContextKeyValue, carrier: *TextMapCarrier) void {
        switch (self.*) {
            .noop => {},
            .w3c => |*propagator| propagator.inject(ctx, carrier),
            .baggage => |*propagator| propagator.inject(ctx, carrier),
            .composite => |propagators| for (propagators) |*propagator| propagator.inject(ctx, carrier),
        }
    }

    /// Extract context from a carrier
    pub fn extract(
        self: *const TextMapPropagator,
        allocator: std.mem.Allocator,
        ctx: []const api.ContextKeyValue,
        carrier: *const TextMapCarrier,
    ) ![]api.ContextKeyValue {
        return switch (self.*) {
            .noop => try api.ContextKeyValue.initOwnedSlice(allocator, ctx),
            .w3c => |*propagator| propagator.extract(allocator, ctx, carrier),
            .baggage => |*propagator| propagator.extract(allocator, ctx, carrier),
            .composite => |propagators| blk: {
                var current = try api.ContextKeyValue.initOwnedSlice(allocator, ctx);
                errdefer api.ContextKeyValue.deinitOwnedSlice(allocator, current);
                for (propagators) |*propagator| {
                    const next = try propagator.extract(allocator, current, carrier);
                    api.ContextKeyValue.deinitOwnedSlice(allocator, current);
                    current = next;
                }
                break :blk current;
            },
        };
    }

    /// Get the fields that this propagator uses
    pub fn fields(self: *const TextMapPropagator, allocator: std.mem.Allocator) ![]const []const u8 {
        return switch (self.*) {
            .noop => try allocator.alloc([]const u8, 0),
            .w3c => |*propagator| propagator.fields(allocator),
            .baggage => |*propagator| propagator.fields(allocator),
            .composite => |propagators| blk: {
                var result = std.ArrayList([]const u8).empty;
                defer result.deinit(allocator);
                for (propagators) |*propagator| {
                    const propagator_fields = try propagator.fields(allocator);
                    defer allocator.free(propagator_fields);
                    for (propagator_fields) |field| {
                        var found = false;
                        for (result.items) |existing| {
                            if (std.mem.eql(u8, existing, field)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) try result.append(allocator, field);
                    }
                }
                break :blk try result.toOwnedSlice(allocator);
            },
        };
    }
};

const w3c_baggage_components = [_]TextMapPropagator{
    .{ .w3c = W3cPropagator.init() },
    .{ .baggage = BaggagePropagator.init() },
};

pub fn createW3cBaggagePropagator() TextMapPropagator {
    return .{ .composite = &w3c_baggage_components };
}

/// Simple HashMap-based carrier for testing
pub const HashMapCarrier = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HashMapCarrier {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HashMapCarrier) void {
        // Free all stored strings
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    fn getImpl(carrier_arg: *const TextMapCarrier, key: []const u8) ?[]const u8 {
        const self = @as(*const HashMapCarrier, @ptrCast(@alignCast(carrier_arg.impl)));
        return self.map.get(key);
    }

    fn setImpl(carrier_arg: *TextMapCarrier, key: []const u8, value: []const u8) void {
        const self = @as(*HashMapCarrier, @ptrCast(@alignCast(carrier_arg.impl)));

        // Copy both key and value to ensure they remain valid
        const owned_key = self.allocator.dupe(u8, key) catch return;
        const owned_value = self.allocator.dupe(u8, value) catch {
            self.allocator.free(owned_key);
            return;
        };

        // If key already exists, free the old values
        if (self.map.fetchRemove(key)) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value);
        }

        self.map.put(owned_key, owned_value) catch {
            self.allocator.free(owned_key);
            self.allocator.free(owned_value);
        };
    }

    fn keysImpl(carrier_arg: *const TextMapCarrier, allocator: std.mem.Allocator) ![][]const u8 {
        const self = @as(*const HashMapCarrier, @ptrCast(@alignCast(carrier_arg.impl)));
        var keys_list = std.ArrayList([]const u8).empty;
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            try keys_list.append(allocator, entry.key_ptr.*);
        }
        return keys_list.toOwnedSlice(allocator);
    }

    pub fn carrier(self: *HashMapCarrier) TextMapCarrier {
        return .{
            .getFn = getImpl,
            .setFn = setImpl,
            .keysFn = keysImpl,
            .impl = @as(*anyopaque, @ptrCast(self)),
        };
    }
};

test "NoopPropagator operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const propagator = TextMapPropagator{ .noop = {} };

    // Create a test context
    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    // Create a test carrier
    var hash_carrier = HashMapCarrier.init(allocator);
    defer hash_carrier.deinit();
    var carrier = hash_carrier.carrier();

    // Inject should do nothing
    propagator.inject(ctx, &carrier);

    // Extract should return the same context
    const extracted = try propagator.extract(allocator, ctx, &carrier);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, extracted);

    // Fields should be empty
    const fields_list = try propagator.fields(allocator);
    defer allocator.free(fields_list);
    try testing.expectEqual(@as(usize, 0), fields_list.len);
}

test "HashMapCarrier operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var hash_carrier = HashMapCarrier.init(allocator);
    defer hash_carrier.deinit();
    var carrier = hash_carrier.carrier();

    // Test set and get
    carrier.set("key1", "value1");
    carrier.set("key2", "value2");

    try testing.expectEqualStrings("value1", carrier.get("key1").?);
    try testing.expectEqualStrings("value2", carrier.get("key2").?);
    try testing.expect(carrier.get("nonexistent") == null);

    // Test keys
    const keys_list = try carrier.keys(allocator);
    defer allocator.free(keys_list);
    try testing.expectEqual(@as(usize, 2), keys_list.len);
}
