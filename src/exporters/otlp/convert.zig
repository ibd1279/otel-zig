const std = @import("std");
const api = @import("otel-api");
const sdk = @import("otel-sdk");

const common_v1 = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("proto/opentelemetry/proto/resource/v1.pb.zig");

// Convert an SDK resource object to a Proto Resource.
pub fn resourceToProto(allocator: std.mem.Allocator, resource: sdk.resource.Resource) !resource_v1.Resource {
    var pb_resource = resource_v1.Resource{};
    for (resource.attributes) |attr| {
        try pb_resource.attributes.append(allocator, try attributeKeyValueToProto(allocator, attr));
    }
    return pb_resource;
}

/// Convert an API AttributeKeyValue to a Proto KeyValue.
pub inline fn attributeKeyValueToProto(allocator: std.mem.Allocator, kv: api.common.AttributeKeyValue) !common_v1.KeyValue {
    return common_v1.KeyValue{
        .key = try allocator.dupe(u8, kv.key),
        .value = try attributeValueToProto(allocator, kv.value),
    };
}

/// Convert an API AttributeValue to a Proto AnyValue.
pub fn attributeValueToProto(allocator: std.mem.Allocator, value: api.common.AttributeValue) !common_v1.AnyValue {
    return switch (value) {
        .string => |s| common_v1.AnyValue{ .value = .{ .string_value = try allocator.dupe(u8, s) } },
        .int => |i| common_v1.AnyValue{ .value = .{ .int_value = i } },
        .float => |f| common_v1.AnyValue{ .value = .{ .double_value = f } },
        .bool => |b| common_v1.AnyValue{ .value = .{ .bool_value = b } },
        .bool_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{};
            for (arr) |item| {
                try pb_array.values.append(allocator, common_v1.AnyValue{
                    .value = .{ .bool_value = item },
                });
            }
            break :blk common_v1.AnyValue{ .value = .{ .array_value = pb_array } };
        },
        .int_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{};
            for (arr) |item| {
                try pb_array.values.append(allocator, common_v1.AnyValue{
                    .value = .{ .int_value = item },
                });
            }
            break :blk common_v1.AnyValue{ .value = .{ .array_value = pb_array } };
        },
        .float_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{};
            for (arr) |item| {
                try pb_array.values.append(allocator, common_v1.AnyValue{
                    .value = .{ .double_value = item },
                });
            }
            break :blk common_v1.AnyValue{ .value = .{ .array_value = pb_array } };
        },
        .string_array => |arr| blk: {
            var pb_array = common_v1.ArrayValue{};
            for (arr) |item| {
                try pb_array.values.append(allocator, common_v1.AnyValue{
                    .value = .{ .string_value = try allocator.dupe(u8, item) },
                });
            }
            break :blk common_v1.AnyValue{ .value = .{ .array_value = pb_array } };
        },
    };
}

pub fn instrumentationScopeToProto(allocator: std.mem.Allocator, scope: api.InstrumentationScope) !common_v1.InstrumentationScope {
    var pb_scope = common_v1.InstrumentationScope{
        .name = try allocator.dupe(u8, scope.name),
        .version = try allocator.dupe(u8, scope.version orelse ""),
    };
    for (scope.attributes) |attr| {
        try pb_scope.attributes.append(allocator, try attributeKeyValueToProto(allocator, attr));
    }
    return pb_scope;
}

test "Protobuf attribute conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test string attribute
    {
        const attr_value = api.common.AttributeValue{ .string = "test_string" };
        var pb_value = try attributeValueToProto(allocator, attr_value);
        defer pb_value.deinit(allocator);
        try testing.expect(pb_value.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.string_value, std.meta.activeTag(pb_value.value.?));
    }

    // Test int attribute
    {
        const attr_value = api.common.AttributeValue{ .int = 42 };
        var pb_value = try attributeValueToProto(allocator, attr_value);
        defer pb_value.deinit(allocator);
        try testing.expect(pb_value.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.int_value, std.meta.activeTag(pb_value.value.?));
        try testing.expectEqual(@as(i64, 42), pb_value.value.?.int_value);
    }

    // Test bool attribute
    {
        const attr_value = api.common.AttributeValue{ .bool = true };
        var pb_value = try attributeValueToProto(allocator, attr_value);
        defer pb_value.deinit(allocator);
        try testing.expect(pb_value.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.bool_value, std.meta.activeTag(pb_value.value.?));
        try testing.expectEqual(true, pb_value.value.?.bool_value);
    }

    // Test float attribute
    {
        const attr_value = api.common.AttributeValue{ .float = 3.14 };
        var pb_value = try attributeValueToProto(allocator, attr_value);
        defer pb_value.deinit(allocator);
        try testing.expect(pb_value.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.double_value, std.meta.activeTag(pb_value.value.?));
        try testing.expectEqual(@as(f64, 3.14), pb_value.value.?.double_value);
    }

    // Test array attribute
    {
        const int_array = [_]i64{ 1, 2, 3 };
        const attr_value = api.common.AttributeValue{ .int_array = &int_array };
        var pb_value = try attributeValueToProto(allocator, attr_value);
        defer pb_value.deinit(allocator);
        try testing.expect(pb_value.value != null);
        try testing.expectEqual(common_v1.AnyValue._value_case.array_value, std.meta.activeTag(pb_value.value.?));
        try testing.expectEqual(@as(usize, 3), pb_value.value.?.array_value.values.items.len);
    }
}
