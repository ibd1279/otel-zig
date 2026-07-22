//! W3C Baggage propagation.

const std = @import("std");
const BaggageKeyValue = @import("baggage.zig").BaggageKeyValue;
const ContextBuilder = @import("../context/context.zig").ContextBuilder;
const ContextKeyValue = @import("../context/context.zig").ContextKeyValue;
const TextMapCarrier = @import("../context/propagation.zig").TextMapCarrier;
const context_keys = @import("../trace/context_keys.zig");

pub const BAGGAGE_HEADER = "baggage";
const max_members = 64;
const max_header_bytes = 8192;

pub const BaggagePropagator = struct {
    pub fn init() BaggagePropagator {
        return .{};
    }

    pub fn inject(_: *const BaggagePropagator, ctx: []const ContextKeyValue, carrier: *TextMapCarrier) void {
        const entry = ContextKeyValue.scanSlice(ctx, context_keys.trace_baggage_key) orelse return;
        const baggage = context_keys.trace_baggage_key.unwrapValue(entry.value) orelse return;

        var header: [max_header_bytes]u8 = undefined;
        var used: usize = 0;
        var count: usize = 0;
        for (baggage) |item| {
            if (count == max_members) break;
            if (!validKey(item.key) or !validMetadata(item.metadata)) continue;
            const separator: usize = if (count == 0) 0 else 1;
            const value_len = escapedLen(item.value);
            const metadata_len = if (item.metadata) |metadata| metadata.len + @intFromBool(metadata.len > 0 and metadata[0] != ';') else 0;
            const member_len = item.key.len + 1 + value_len + metadata_len;
            if (used + separator + member_len > header.len) break;

            if (separator == 1) header[used] = ',';
            used += separator;
            @memcpy(header[used..][0..item.key.len], item.key);
            used += item.key.len;
            header[used] = '=';
            used += 1;
            used += escapeValue(header[used..], item.value);
            if (item.metadata) |metadata| {
                if (metadata.len > 0 and metadata[0] != ';') {
                    header[used] = ';';
                    used += 1;
                }
                @memcpy(header[used..][0..metadata.len], metadata);
                used += metadata.len;
            }
            count += 1;
        }
        if (used > 0) carrier.set(BAGGAGE_HEADER, header[0..used]);
    }

    pub fn extract(
        _: *const BaggagePropagator,
        allocator: std.mem.Allocator,
        ctx: []const ContextKeyValue,
        carrier: *const TextMapCarrier,
    ) ![]ContextKeyValue {
        const header = carrier.get(BAGGAGE_HEADER) orelse return ContextKeyValue.initOwnedSlice(allocator, ctx);
        if (header.len == 0) return ContextKeyValue.initOwnedSlice(allocator, ctx);

        const baggage = parseHeader(allocator, header) catch return ContextKeyValue.initOwnedSlice(allocator, ctx);
        defer BaggageKeyValue.deinitOwnedSlice(allocator, baggage);

        const builder = ContextBuilder.init(allocator)
            .addMany(ctx)
            .add(.{ .key = context_keys.trace_baggage_key.key_id, .value = .{ .baggage = baggage } });
        return builder.finish(allocator);
    }

    pub fn fields(_: *const BaggagePropagator, allocator: std.mem.Allocator) ![]const []const u8 {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = BAGGAGE_HEADER;
        return result;
    }
};

fn parseHeader(allocator: std.mem.Allocator, header: []const u8) ![]BaggageKeyValue {
    if (header.len > max_header_bytes) return error.InvalidBaggage;

    var entries = std.ArrayList(BaggageKeyValue).empty;
    errdefer {
        for (entries.items) |entry| entry.deinitOwned(allocator);
        entries.deinit(allocator);
    }

    var members = std.mem.splitScalar(u8, header, ',');
    while (members.next()) |raw_member| {
        const member = std.mem.trim(u8, raw_member, " \t");
        const semicolon = std.mem.indexOfScalar(u8, member, ';');
        const key_value = if (semicolon) |index| member[0..index] else member;
        const metadata = if (semicolon) |index| member[index..] else null;
        const equals = std.mem.indexOfScalar(u8, key_value, '=') orelse return error.InvalidBaggage;
        const key = std.mem.trim(u8, key_value[0..equals], " \t");
        const encoded_value = std.mem.trim(u8, key_value[equals + 1 ..], " \t");
        if (!validKey(key) or !validEncodedValue(encoded_value) or !validMetadata(metadata)) return error.InvalidBaggage;

        const value = try unescapeValue(allocator, encoded_value);
        defer allocator.free(value);
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidBaggage;
        const owned = try BaggageKeyValue.initOwned(allocator, key, value, metadata);

        var replaced = false;
        for (entries.items) |*existing| {
            if (std.mem.eql(u8, existing.key, key)) {
                existing.deinitOwned(allocator);
                existing.* = owned;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            if (entries.items.len == max_members) {
                owned.deinitOwned(allocator);
                return error.InvalidBaggage;
            }
            try entries.append(allocator, owned);
        }
    }
    return entries.toOwnedSlice(allocator);
}

fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| if (!isToken(byte)) return false;
    return true;
}

fn isToken(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn validEncodedValue(value: []const u8) bool {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte < 0x21 or byte > 0x7e or byte == '"' or byte == ',' or byte == ';' or byte == '\\') return false;
        if (byte == '%') {
            if (index + 2 >= value.len) return false;
            _ = std.fmt.charToDigit(value[index + 1], 16) catch return false;
            _ = std.fmt.charToDigit(value[index + 2], 16) catch return false;
            index += 2;
        }
    }
    return true;
}

fn validMetadata(metadata: ?[]const u8) bool {
    const raw = metadata orelse return true;
    if (raw.len == 0) return true;
    var properties = std.mem.splitScalar(u8, if (raw[0] == ';') raw[1..] else raw, ';');
    while (properties.next()) |raw_property| {
        const property = std.mem.trim(u8, raw_property, " \t");
        if (property.len == 0) return false;
        if (std.mem.indexOfScalar(u8, property, '=')) |equals| {
            if (!validKey(std.mem.trim(u8, property[0..equals], " \t"))) return false;
            if (!validEncodedValue(std.mem.trim(u8, property[equals + 1 ..], " \t"))) return false;
        } else if (!validKey(property)) return false;
    }
    return true;
}

fn escapedLen(value: []const u8) usize {
    var result: usize = 0;
    for (value) |byte| result += if (shouldEscape(byte)) 3 else 1;
    return result;
}

fn shouldEscape(byte: u8) bool {
    return byte == '%' or byte < 0x21 or byte > 0x7e or byte == '"' or byte == ',' or byte == ';' or byte == '\\';
}

fn escapeValue(destination: []u8, value: []const u8) usize {
    const hex = "0123456789ABCDEF";
    var used: usize = 0;
    for (value) |byte| {
        if (shouldEscape(byte)) {
            destination[used] = '%';
            destination[used + 1] = hex[byte >> 4];
            destination[used + 2] = hex[byte & 0x0f];
            used += 3;
        } else {
            destination[used] = byte;
            used += 1;
        }
    }
    return used;
}

fn unescapeValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, value.len);
    errdefer allocator.free(result);
    var source: usize = 0;
    var destination: usize = 0;
    while (source < value.len) {
        if (value[source] == '%') {
            const high = std.fmt.charToDigit(value[source + 1], 16) catch return error.InvalidBaggage;
            const low = std.fmt.charToDigit(value[source + 2], 16) catch return error.InvalidBaggage;
            result[destination] = (high << 4) | low;
            source += 3;
        } else {
            result[destination] = value[source];
            source += 1;
        }
        destination += 1;
    }
    return allocator.realloc(result, destination);
}

test "W3C baggage inject and extract" {
    const allocator = std.testing.allocator;
    const baggage = [_]BaggageKeyValue{
        .{ .key = "user.id", .value = "nate, admin", .metadata = ";tenant=waow" },
        .{ .key = "empty", .value = "" },
    };
    const ctx = [_]ContextKeyValue{.{ .key = context_keys.trace_baggage_key.key_id, .value = .{ .baggage = @constCast(&baggage) } }};
    var hash_carrier = @import("../context/propagation.zig").HashMapCarrier.init(allocator);
    defer hash_carrier.deinit();
    var carrier = hash_carrier.carrier();
    const propagator = BaggagePropagator.init();

    propagator.inject(&ctx, &carrier);
    try std.testing.expectEqualStrings("user.id=nate%2C%20admin;tenant=waow,empty=", carrier.get(BAGGAGE_HEADER).?);

    const extracted = try propagator.extract(allocator, &.{}, &carrier);
    defer ContextKeyValue.deinitOwnedSlice(allocator, extracted);
    const extracted_entry = ContextKeyValue.scanSlice(extracted, context_keys.trace_baggage_key).?;
    const extracted_baggage = context_keys.trace_baggage_key.unwrapValue(extracted_entry.value).?;
    try std.testing.expectEqual(@as(usize, 2), extracted_baggage.len);
    try std.testing.expectEqualStrings("nate, admin", extracted_baggage[0].value);
    try std.testing.expectEqualStrings(";tenant=waow", extracted_baggage[0].metadata.?);
}

test "invalid baggage leaves parent context unchanged" {
    const allocator = std.testing.allocator;
    var hash_carrier = @import("../context/propagation.zig").HashMapCarrier.init(allocator);
    defer hash_carrier.deinit();
    var carrier = hash_carrier.carrier();
    carrier.set(BAGGAGE_HEADER, "valid=one,invalid member");
    const parent = [_]ContextKeyValue{.{ .key = 42, .value = .{ .string = "kept" } }};
    const propagator = BaggagePropagator.init();
    const extracted = try propagator.extract(allocator, &parent, &carrier);
    defer ContextKeyValue.deinitOwnedSlice(allocator, extracted);
    try std.testing.expectEqual(@as(usize, 1), extracted.len);
    try std.testing.expectEqualStrings("kept", extracted[0].value.string);
}
