//! W3C compliant TraceState implementation
//!
//! TraceState carries tracing-system specific context in a list of key-value pairs.
//! TraceState allows different vendors to propagate additional information and
//! inter-operate with their legacy id formats.
//!
//! This implementation follows the W3C Trace Context specification:
//! https://www.w3.org/TR/trace-context/#tracestate-header
//!
//! ## Key Requirements
//! - Maximum 32 key-value pairs
//! - Keys follow specific ABNF grammar (simple-key or multi-tenant-key)
//! - Values are 0-256 printable ASCII characters (except comma and equals)
//! - All operations are immutable (return new TraceState instances)
//! - Proper W3C validation for interoperability

const std = @import("std");
const api = struct {
    const common = struct {
        const ErrorInfo = @import("../common/error_handler.zig").ErrorInfo;
        const reportValidationError = @import("../common/error_handler.zig").reportValidationError;
        const reportError = @import("../common/error_handler.zig").reportError;
    };
};

// W3C specification constants
const MAX_KEY_VALUE_PAIRS = 32;
const MAX_KEY_LENGTH = 256;
const MAX_VALUE_LENGTH = 256;

/// W3C compliant TraceState implementation
///
/// Per W3C Trace Context specification (https://www.w3.org/TR/trace-context/):
/// tracestate format: list-member = (key "=" value) / OWS
/// Keys always require an accompanying value (though value may be empty string)
pub const StateKeyValue = struct {
    pub const max_pairs = MAX_KEY_VALUE_PAIRS;

    /// The entry key (non-owning string slice)
    key: []const u8,

    /// The entry value (non-owning optional string slice)
    value: ?[]const u8,

    /// Scan for a key in the slice.
    pub fn scanSlice(haystack: []StateKeyValue, needle: []const u8) ?StateKeyValue {
        // Iterate forwards as trace state is supposed to prepend.
        // Per W3C Trace Context specification (https://www.w3.org/TR/trace-context/):
        // "Modified keys MUST be moved to the beginning (left) of the list"
        // "The new key/value pair SHOULD be added to the beginning of the list"
        // Source: https://github.com/w3c/trace-context/blob/main/spec/20-http_request_header_format.md
        for (haystack) |entry| {
            if (std.mem.eql(u8, entry.key, needle)) {
                return entry;
            }
        }
        return null;
    }

    /// create a non-owning slice of valid values from the provided string. Returns the number of set headers.
    pub fn fromString(source: []const u8, target: *[MAX_KEY_VALUE_PAIRS]StateKeyValue) []StateKeyValue {
        var count: usize = 0;
        var iter = std.mem.splitScalar(u8, source, ',');
        while (iter.next()) |slice| {
            // Find the equals sign
            if (std.mem.find(u8, slice, "=")) |eq_pos| {
                const entry = StateKeyValue{
                    .key = std.mem.trim(u8, slice[0..eq_pos], " \t"),
                    .value = std.mem.trim(u8, slice[eq_pos + 1 ..], " \t"),
                };

                // Validate key and value
                if (entry.validationErrorInfo()) |error_info| {
                    api.common.reportError(error_info);
                    // skip invalid entries.
                    continue;
                }
                target[count] = entry;
                count += 1;
            } else {
                api.common.reportValidationError(
                    .general,
                    "StateKeyValue.fromString",
                    "Invalid trace state entry",
                    "lacks '=' in the entry",
                );
                // skipping entries that lack a '='
            }
        }
        return target[0..count];
    }

    /// Deep copy a StateKeyValue. Must call `deinitOwned` on the return instance.
    pub fn initOwned(allocator: std.mem.Allocator, entry: StateKeyValue) !StateKeyValue {
        const owned_key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(owned_key);
        const owned_value = if (entry.value) |v| try allocator.dupe(u8, v) else null;
        errdefer if (owned_value) |v| allocator.free(v);
        return .{
            .key = owned_key,
            .value = owned_value,
        };
    }

    /// Deep copy a StateKeyValue slice. Must call `deinitOwnedSlice` on the return instance.
    pub fn initOwnedSlice(allocator: std.mem.Allocator, unowned: []StateKeyValue) ![]StateKeyValue {
        var owned = try allocator.alloc(StateKeyValue, unowned.len);
        errdefer allocator.free(owned);
        for (0..unowned.len) |h| {
            errdefer if (h > 0) for (0..h - 1) |i| owned[i].deinitOwned(allocator);
            owned[h] = try initOwned(allocator, unowned[h]);
        }
        return owned;
    }

    /// Destroy a deep copied StateKeyValue.
    pub fn deinitOwned(self: StateKeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.value) |v| allocator.free(v);
    }

    /// Destroy a deep copied slice of StateKeyVlaue.
    pub fn deinitOwnedSlice(allocator: std.mem.Allocator, slice: []const StateKeyValue) void {
        for (0..slice.len) |h| slice[h].deinitOwned(allocator);
        allocator.free(slice);
    }

    pub fn validationErrorInfo(self: StateKeyValue) ?api.common.ErrorInfo {
        if (!validateKey(self.key)) {
            return .{
                .component = .general,
                .operation = "StateKeyValue.key validation",
                .error_type = .validation,
                .message = "Invalid trace state key provided",
                .context = "key doesn't match w3c spec",
            };
        }
        if (self.value) |value| {
            if (!validateValue(value)) {
                return .{
                    .component = .general,
                    .operation = "StateKeyValue.value validation",
                    .error_type = .validation,
                    .message = "Invalid trace state value provided",
                    .context = "value doesn't match w3c spec",
                };
            }
        }
        return null;
    }

    /// Validate key according to W3C specification
    // Keys must follow ABNF grammar: simple-key or multi-tenant-key format
    // simple-key = lcalpha 0*255( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
    // tenant-id = ( lcalpha / DIGIT ) 0*240( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
    // system-id = lcalpha 0*13( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
    // multi-tenant-key = tenant-id "@" system-id
    fn validateKey(key: []const u8) bool {
        // Check for multi-tenant key (contains @)
        if (std.mem.find(u8, key, "@")) |at_pos| {
            return validateMultiTenantKey(key, at_pos);
        } else {
            return validateSimpleKey(key, MAX_KEY_LENGTH, false);
        }
    }

    /// Validate simple key format
    fn validateSimpleKey(key: []const u8, comptime max_len: usize, comptime digit_start: bool) bool {
        // comptime branch.
        if (digit_start) {
            // simple-key = lcalpha 0*max_len( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
            // First character must be lowercase letter
            if (key.len == 0 or !(std.ascii.isLower(key[0]) or std.ascii.isDigit(key[0]))) {
                return false;
            }
        } else {
            // tenant-id = ( lcalpha / DIGIT ) 0*240( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
            // First character must be lowercase letter
            if (key.len == 0 or !std.ascii.isLower(key[0])) {
                return false;
            }
        }

        // must be shorter than required len
        if (key.len > max_len) {
            return false;
        }

        // Subsequent characters: lowercase letters, digits, or allowed symbols
        for (key[1..]) |c| {
            if (!std.ascii.isLower(c) and
                !std.ascii.isDigit(c) and
                c != '_' and c != '-' and c != '*' and c != '/')
            {
                return false;
            }
        }

        return true;
    }

    /// Validate multi-tenant key format
    fn validateMultiTenantKey(key: []const u8, at_pos: usize) bool {
        // multi-tenant-key = tenant-id "@" system-id
        // tenant-id = ( lcalpha / DIGIT ) 0*240( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
        // system-id = lcalpha 0*13( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )

        if (at_pos == 0 or at_pos >= key.len - 1) {
            return false; // @ cannot be at start or end
        }

        const tenant_id = key[0..at_pos];
        const system_id = key[at_pos + 1 ..];

        if (!validateSimpleKey(system_id, 14, false)) {
            return false;
        }

        if (!validateSimpleKey(tenant_id, 241, true)) {
            return false;
        }

        return true;
    }

    /// Validate value according to W3C specification
    /// Values: 0-256 printable ASCII chars (0x20-0x7E) except comma (0x2C) and equals (0x3D)
    fn validateValue(value: []const u8) bool {
        if (value.len > MAX_VALUE_LENGTH) {
            return false;
        }

        for (value) |c| {
            // Check printable ASCII range, excluding comma and equals
            if (c < 0x20 or c > 0x7E or c == ',' or c == '=') {
                return false;
            }
        }

        return true;
    }

    test "TraceState key validation" {
        // Valid simple keys
        try std.testing.expect(validateKey("vendor"));
        try std.testing.expect(validateKey("a"));
        try std.testing.expect(validateKey("vendor123"));
        try std.testing.expect(validateKey("vendor_name"));
        try std.testing.expect(validateKey("vendor-name"));
        try std.testing.expect(validateKey("vendor*name"));
        try std.testing.expect(validateKey("vendor/name"));

        // Valid multi-tenant keys
        try std.testing.expect(validateKey("tenant@system"));
        try std.testing.expect(validateKey("123@vendor"));
        try std.testing.expect(validateKey("tenant123@system_name"));

        // Invalid keys
        try std.testing.expect(!validateKey("")); // empty
        try std.testing.expect(!validateKey("Vendor")); // uppercase
        try std.testing.expect(!validateKey("123vendor")); // simple key can't start with digit
        try std.testing.expect(!validateKey("vendor@")); // multi-tenant missing system
        try std.testing.expect(!validateKey("@system")); // multi-tenant missing tenant
        try std.testing.expect(!validateKey("vendor@@system")); // double @
        try std.testing.expect(!validateKey("vendor name")); // space not allowed
    }

    test "TraceState value validation" {
        // Valid values
        try std.testing.expect(validateValue(""));
        try std.testing.expect(validateValue("simple_value"));
        try std.testing.expect(validateValue("Value123"));
        try std.testing.expect(validateValue("!@#$%^&*()_+-[]{}|;':\"<>?./~`"));

        // Invalid values
        try std.testing.expect(!validateValue("value,with,comma"));
        try std.testing.expect(!validateValue("value=with=equals"));
        try std.testing.expect(!validateValue("value\nwith\nnewline"));
        try std.testing.expect(!validateValue("value\twith\ttab"));

        // Test length limit
        const long_value = "a" ** 257;
        try std.testing.expect(!validateValue(long_value));
        const max_value = "a" ** 256;
        try std.testing.expect(validateValue(max_value));
    }

    /// Compare two StateKeyValue pairs for equality.
    ///
    /// Equality is defined as a byte comparison on the key and
    /// invoking the equal opretor for the value.
    pub fn eql(self: StateKeyValue, other: StateKeyValue) bool {
        const values_match = blk: {
            const sv = self.value orelse break :blk other.value == null;
            const ov = other.value orelse return false;
            break :blk std.mem.eql(u8, sv, ov);
        };
        const keys_match = std.mem.eql(u8, self.key, other.key);
        return keys_match and values_match;
    }

    /// Hash the StateKeyValue for use in hash maps
    pub fn hash(self: StateKeyValue, hasher: *std.hash.Wyhash) void {
        hasher.update(self.key);
        self.value.hash(hasher);
    }

    /// Format the StateKeyValue for debugging/logging
    pub fn format(
        self: StateKeyValue,
        writer: anytype,
    ) !void {
        if (self.value) |v| try writer.print("{s}={s}", .{ self.key, v }) else try writer.print("{s}={{null}}", .{self.key});
    }
};

pub const StateBuilder = @import("../common/builder.zig").Builder(StateKeyValue);

pub const OtState = struct {
    th: ?u56 = null,
    rv: ?u56 = null,

    pub fn fromString(source: []const u8) !OtState {
        var result = OtState{};
        var iter = std.mem.splitScalar(u8, source, ';');
        while (iter.next()) |slice| {
            if (std.mem.find(u8, slice, ":")) |eq_pos| {
                const key = slice[0..eq_pos];
                const value = slice[eq_pos + 1 ..];
                if (std.mem.eql(u8, "th", key) and value.len <= 14) {
                    var buffer = [_]u8{0} ** 7;
                    for (0..7) |h| {
                        if (h * 2 >= value.len) break;
                        buffer[h] |= (try std.fmt.parseInt(u8, value[h * 2 .. h * 2 + 1], 16)) << 4;
                        if (h * 2 + 1 >= value.len) break;
                        buffer[h] |= try std.fmt.parseInt(u8, value[h * 2 + 1 .. h * 2 + 2], 16);
                    }
                    result.th = std.mem.readInt(u56, &buffer, .big);
                } else if (std.mem.eql(u8, "rv", key) and value.len == 14) {
                    var buffer = [_]u8{0} ** 7;
                    for (0..buffer.len) |h| buffer[h] = try std.fmt.parseInt(u8, value[h * 2 .. h * 2 + 2], 16);
                    result.rv = std.mem.readInt(u56, &buffer, .big);
                }
            }
        }
        return result;
    }
};

// Tests
test "TraceState fromString basic parsing" {

    // Test empty string
    {
        const allocator = std.testing.allocator;
        const errors = @import("../common/error_handler.zig");
        var mock_errorhandler = errors.MockErrorHandler.init(allocator);
        errors.setMockErrorHandler(&mock_errorhandler);
        defer mock_errorhandler.deinit();
        defer errors.clearMockErrorHandler();

        var buffer: [MAX_KEY_VALUE_PAIRS]StateKeyValue = undefined;
        const empty_state = StateKeyValue.fromString("", &buffer);
        try std.testing.expectEqual(@as(usize, 0), empty_state.len);

        // It doesn't fail, but treats it as a validation error.
        try std.testing.expectEqual(@as(usize, 1), mock_errorhandler.errors.items.len);
    }

    // Test single entry
    {
        var buffer: [MAX_KEY_VALUE_PAIRS]StateKeyValue = undefined;
        const single_state = StateKeyValue.fromString("vendor1=value1", &buffer);
        try std.testing.expectEqual(@as(usize, 1), single_state.len);
        const result1 = StateKeyValue.scanSlice(single_state, "vendor1");
        try std.testing.expect(result1 != null);
        try std.testing.expect(result1.?.value != null);
        try std.testing.expectEqualStrings("value1", result1.?.value.?);

        const result2 = StateKeyValue.scanSlice(single_state, "vendor2");
        try std.testing.expect(result2 == null);
    }

    // Test two entries
    {
        var buffer: [MAX_KEY_VALUE_PAIRS]StateKeyValue = undefined;
        const double_state = StateKeyValue.fromString("vendor1=value1,vendor2=value2", &buffer);
        try std.testing.expectEqual(@as(usize, 2), double_state.len);
        const result1 = StateKeyValue.scanSlice(double_state, "vendor1");
        try std.testing.expect(result1 != null);
        try std.testing.expect(result1.?.value != null);
        try std.testing.expectEqualStrings("value1", result1.?.value.?);

        const result2 = StateKeyValue.scanSlice(double_state, "vendor2");
        try std.testing.expect(result2 != null);
        try std.testing.expect(result2.?.value != null);
        try std.testing.expectEqualStrings("value2", result2.?.value.?);
    }
}

test "TraceState put operation" {
    const allocator = std.testing.allocator;

    // Start with empty state
    const trace_state = try StateBuilder.init(allocator)
        .add(.{ .key = "vendor1", .value = "value1" })
        .add(.{ .key = "vendor2", .value = "value2" })
        .add(.{ .key = "vendor3", .value = "value3" })
        .finish(allocator);
    defer StateKeyValue.deinitOwnedSlice(allocator, trace_state);

    // Add first entry
    try std.testing.expectEqual(@as(usize, 3), trace_state.len);

    const trace_state_next = try StateBuilder.init(allocator)
        .addMany(trace_state)
        .add(.{ .key = "0tenant@example", .value = null })
        .addFirst(.{ .key = "ot", .value = "th:8;rv:6e6d1a75832a2f" })
        .finish(allocator);
    defer StateKeyValue.deinitOwnedSlice(allocator, trace_state_next);

    // Add second entry (should be at the beginning)
    try std.testing.expectEqual(@as(usize, 5), trace_state_next.len);

    const value_found = StateKeyValue.scanSlice(trace_state_next, "0tenant@example");
    try std.testing.expect(value_found != null);
    try std.testing.expect(value_found.?.value == null);
    try std.testing.expectEqualStrings("0tenant@example", value_found.?.key);

    // validate the order, as 'ot' should be the first.
    try std.testing.expectEqualStrings("ot", trace_state_next[0].key);
    try std.testing.expectEqualStrings("0tenant@example", trace_state_next[4].key);
}

test "TraceState remove operation" {
    const allocator = std.testing.allocator;

    // Create state with multiple entries
    var buffer: [MAX_KEY_VALUE_PAIRS]StateKeyValue = undefined;
    const state = StateKeyValue.fromString("vendor1=value1,vendor2=value2,vendor3=value3", &buffer);
    try std.testing.expectEqual(@as(usize, 3), state.len);

    // Remove middle entry
    const state2 = try StateBuilder.init(allocator)
        .addMany(state)
        .remove("vendor2")
        .finish(allocator);
    defer StateKeyValue.deinitOwnedSlice(allocator, state2);

    try std.testing.expectEqual(@as(usize, 2), state2.len);
    const result1 = StateKeyValue.scanSlice(state2, "vendor1");
    try std.testing.expect(result1 != null);
    try std.testing.expect(result1.?.value != null);
    try std.testing.expectEqualStrings("value1", result1.?.value.?);

    const result2 = StateKeyValue.scanSlice(state2, "vendor3");
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.?.value != null);
    try std.testing.expectEqualStrings("value3", result2.?.value.?);

    // Remove non-existent entry (should be no-op)
    const state3 = try StateBuilder.init(allocator)
        .addMany(state)
        .remove("nonexistent")
        .finish(allocator);
    defer StateKeyValue.deinitOwnedSlice(allocator, state3);

    try std.testing.expectEqual(@as(usize, 3), state3.len);
}

test "TraceState parsing edge cases" {
    const allocator = std.testing.allocator;

    const errors = @import("../common/error_handler.zig");
    var mock_errorhandler = errors.MockErrorHandler.init(allocator);
    errors.setMockErrorHandler(&mock_errorhandler);
    defer mock_errorhandler.deinit();
    defer errors.clearMockErrorHandler();

    // Test with whitespace
    {
        var buffer: [MAX_KEY_VALUE_PAIRS]StateKeyValue = undefined;
        const state_ws = StateKeyValue.fromString(" vendor1 = value1 , vendor2 = value2 ,\t3foo@bar\t=\tvalue3", &buffer);
        try std.testing.expectEqual(@as(usize, 3), state_ws.len); // invalid values are skipped.
        const result1 = StateKeyValue.scanSlice(state_ws, "vendor1");
        try std.testing.expect(result1 != null);
        try std.testing.expect(result1.?.value != null);
        try std.testing.expectEqualStrings("value1", result1.?.value.?);

        const result2 = StateKeyValue.scanSlice(state_ws, "vendor2");
        try std.testing.expect(result2 != null);
        try std.testing.expect(result2.?.value != null);
        try std.testing.expectEqualStrings("value2", result2.?.value.?);

        const result3 = StateKeyValue.scanSlice(state_ws, "3foo@bar");
        try std.testing.expect(result3 != null);
        try std.testing.expect(result3.?.value != null);
        try std.testing.expectEqualStrings("value3", result3.?.value.?);

        // check the mock error handler.
        try std.testing.expectEqual(@as(usize, 0), mock_errorhandler.errors.items.len);
    }

    mock_errorhandler.clearErrors();

    // Test with empty members (should be skipped)
    {
        var buffer: [MAX_KEY_VALUE_PAIRS]StateKeyValue = undefined;
        const state_empty = StateKeyValue.fromString("vendor1=value1,,vendor2=value2,_foobar=invalid", &buffer);
        try std.testing.expectEqual(@as(usize, 2), state_empty.len);

        const result1 = StateKeyValue.scanSlice(state_empty, "vendor1");
        try std.testing.expect(result1 != null);
        try std.testing.expect(result1.?.value != null);
        try std.testing.expectEqualStrings("value1", result1.?.value.?);

        const result2 = StateKeyValue.scanSlice(state_empty, "vendor2");
        try std.testing.expect(result2 != null);
        try std.testing.expect(result2.?.value != null);
        try std.testing.expectEqualStrings("value2", result2.?.value.?);

        // check the mock error handler.
        try std.testing.expectEqual(@as(usize, 2), mock_errorhandler.errors.items.len);
    }

    mock_errorhandler.clearErrors();

    // Test invalid format (should be an empty slice)
    {
        var buffer: [MAX_KEY_VALUE_PAIRS]StateKeyValue = undefined;
        const state_empty = StateKeyValue.fromString("invalid_format", &buffer);
        try std.testing.expectEqual(@as(usize, 0), state_empty.len);

        // check the mock error handler.
        try std.testing.expectEqual(@as(usize, 1), mock_errorhandler.errors.items.len);
    }
}
