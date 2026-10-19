//! OpenTelemetry Log Severity Levels
//!
//! This module defines severity levels for log records according to the OpenTelemetry
//! specification. Each major severity level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)
//! has 4 sub-levels for fine-grained control.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/data-model.md#field-severitynumber

const std = @import("std");

/// Severity levels for log records, matching OpenTelemetry specification.
/// Values range from 1-24, with 0 reserved for Invalid/Unspecified.
pub const Severity = enum(u8) {
    /// Invalid or unspecified severity
    invalid = 0,

    /// Trace level logging - finest granularity
    trace = 1,
    trace2 = 2,
    trace3 = 3,
    trace4 = 4,

    /// Debug level logging - debugging information
    debug = 5,
    debug2 = 6,
    debug3 = 7,
    debug4 = 8,

    /// Info level logging - informational messages
    info = 9,
    info2 = 10,
    info3 = 11,
    info4 = 12,

    /// Warning level logging - warning conditions
    warn = 13,
    warn2 = 14,
    warn3 = 15,
    warn4 = 16,

    /// Error level logging - error conditions
    @"error" = 17,
    error2 = 18,
    error3 = 19,
    error4 = 20,

    /// Fatal level logging - fatal conditions
    fatal = 21,
    fatal2 = 22,
    fatal3 = 23,
    fatal4 = 24,

    /// Convert severity to its numeric value
    pub fn toNumber(self: Severity) u8 {
        return @intFromEnum(self);
    }

    /// Convert severity to standard text representation (uppercase)
    pub fn toText(self: Severity) []const u8 {
        return switch (self) {
            .invalid => "INVALID",
            .trace => "TRACE",
            .trace2 => "TRACE2",
            .trace3 => "TRACE3",
            .trace4 => "TRACE4",
            .debug => "DEBUG",
            .debug2 => "DEBUG2",
            .debug3 => "DEBUG3",
            .debug4 => "DEBUG4",
            .info => "INFO",
            .info2 => "INFO2",
            .info3 => "INFO3",
            .info4 => "INFO4",
            .warn => "WARN",
            .warn2 => "WARN2",
            .warn3 => "WARN3",
            .warn4 => "WARN4",
            .@"error" => "ERROR",
            .error2 => "ERROR2",
            .error3 => "ERROR3",
            .error4 => "ERROR4",
            .fatal => "FATAL",
            .fatal2 => "FATAL2",
            .fatal3 => "FATAL3",
            .fatal4 => "FATAL4",
        };
    }

    /// Convert severity to short text representation (base level only)
    pub fn toShortText(self: Severity) []const u8 {
        return switch (self) {
            .invalid => "INVALID",
            .trace, .trace2, .trace3, .trace4 => "TRACE",
            .debug, .debug2, .debug3, .debug4 => "DEBUG",
            .info, .info2, .info3, .info4 => "INFO",
            .warn, .warn2, .warn3, .warn4 => "WARN",
            .@"error", .error2, .error3, .error4 => "ERROR",
            .fatal, .fatal2, .fatal3, .fatal4 => "FATAL",
        };
    }

    /// Check if this severity is valid (not Invalid)
    pub fn isValid(self: Severity) bool {
        return self != .invalid;
    }

    /// Check if this severity is at least as severe as another
    pub fn isAtLeast(self: Severity, other: Severity) bool {
        return self.toNumber() >= other.toNumber();
    }

    /// Check if this severity is more severe than another
    pub fn isMoreSevereThan(self: Severity, other: Severity) bool {
        return self.toNumber() > other.toNumber();
    }

    /// Get the base severity level (e.g., Error2 -> Error)
    pub fn getBaseLevel(self: Severity) Severity {
        return switch (self) {
            .invalid => .invalid,
            .trace, .trace2, .trace3, .trace4 => .trace,
            .debug, .debug2, .debug3, .debug4 => .debug,
            .info, .info2, .info3, .info4 => .info,
            .warn, .warn2, .warn3, .warn4 => .warn,
            .@"error", .error2, .error3, .error4 => .@"error",
            .fatal, .fatal2, .fatal3, .fatal4 => .fatal,
        };
    }

    /// Format severity for display
    pub fn format(
        self: Severity,
        writer: anytype,
    ) !void {
        try writer.writeAll(self.toText());
    }
};

/// Error type for severity parsing
pub const SeverityError = error{
    InvalidSeverityNumber,
    InvalidSeverityText,
};

/// Create a Severity from a numeric value
pub fn fromNumber(value: u8) SeverityError!Severity {
    if (value > 24) {
        return error.InvalidSeverityNumber;
    }
    return @enumFromInt(value);
}

/// Create a Severity from text (case-insensitive)
pub fn fromText(text: []const u8) SeverityError!Severity {
    // Convert to uppercase for comparison
    var buf: [7]u8 = undefined; // Max length is "INVALID"
    if (text.len > buf.len) {
        return error.InvalidSeverityText;
    }

    const upper = std.ascii.upperString(&buf, text);

    // Check all severity values
    const enum_info = @typeInfo(Severity).@"enum";
    inline for (enum_info.field_names, enum_info.field_values) |_, value| {
        const severity: Severity = @enumFromInt(value);
        if (std.mem.eql(u8, upper, severity.toText())) {
            return severity;
        }
    }

    // Also accept short forms (e.g., "ERROR" for any ERROR level)
    if (std.mem.eql(u8, upper, "TRACE")) return .trace;
    if (std.mem.eql(u8, upper, "DEBUG")) return .debug;
    if (std.mem.eql(u8, upper, "INFO")) return .info;
    if (std.mem.eql(u8, upper, "WARN")) return .warn;
    if (std.mem.eql(u8, upper, "ERROR")) return .@"error";
    if (std.mem.eql(u8, upper, "FATAL")) return .fatal;

    return error.InvalidSeverityText;
}

// Tests

test "Severity numeric values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 0), Severity.invalid.toNumber());
    try testing.expectEqual(@as(u8, 1), Severity.trace.toNumber());
    try testing.expectEqual(@as(u8, 5), Severity.debug.toNumber());
    try testing.expectEqual(@as(u8, 9), Severity.info.toNumber());
    try testing.expectEqual(@as(u8, 13), Severity.warn.toNumber());
    try testing.expectEqual(@as(u8, 17), Severity.@"error".toNumber());
    try testing.expectEqual(@as(u8, 21), Severity.fatal.toNumber());
    try testing.expectEqual(@as(u8, 24), Severity.fatal4.toNumber());
}

test "Severity text representation" {
    const testing = std.testing;

    try testing.expectEqualStrings("INVALID", Severity.invalid.toText());
    try testing.expectEqualStrings("TRACE", Severity.trace.toText());
    try testing.expectEqualStrings("DEBUG3", Severity.debug3.toText());
    try testing.expectEqualStrings("INFO", Severity.info.toText());
    try testing.expectEqualStrings("WARN2", Severity.warn2.toText());
    try testing.expectEqualStrings("ERROR", Severity.@"error".toText());
    try testing.expectEqualStrings("FATAL4", Severity.fatal4.toText());
}

test "Severity short text representation" {
    const testing = std.testing;

    try testing.expectEqualStrings("TRACE", Severity.trace2.toShortText());
    try testing.expectEqualStrings("DEBUG", Severity.debug3.toShortText());
    try testing.expectEqualStrings("INFO", Severity.info4.toShortText());
    try testing.expectEqualStrings("WARN", Severity.warn.toShortText());
    try testing.expectEqualStrings("ERROR", Severity.error2.toShortText());
    try testing.expectEqualStrings("FATAL", Severity.fatal3.toShortText());
}

test "Severity validation" {
    const testing = std.testing;

    try testing.expect(!Severity.invalid.isValid());
    try testing.expect(Severity.trace.isValid());
    try testing.expect(Severity.debug.isValid());
    try testing.expect(Severity.info.isValid());
    try testing.expect(Severity.warn.isValid());
    try testing.expect(Severity.@"error".isValid());
    try testing.expect(Severity.fatal.isValid());
}

test "Severity comparison" {
    const testing = std.testing;

    try testing.expect(Severity.@"error".isAtLeast(.warn));
    try testing.expect(Severity.fatal.isAtLeast(.fatal));
    try testing.expect(!Severity.info.isAtLeast(.warn));

    try testing.expect(Severity.@"error".isMoreSevereThan(.warn));
    try testing.expect(!Severity.@"error".isMoreSevereThan(.@"error"));
    try testing.expect(!Severity.info.isMoreSevereThan(.warn));
}

test "Severity base level" {
    const testing = std.testing;

    try testing.expectEqual(Severity.trace, Severity.trace3.getBaseLevel());
    try testing.expectEqual(Severity.debug, Severity.debug2.getBaseLevel());
    try testing.expectEqual(Severity.info, Severity.info.getBaseLevel());
    try testing.expectEqual(Severity.warn, Severity.warn4.getBaseLevel());
    try testing.expectEqual(Severity.@"error", Severity.error2.getBaseLevel());
    try testing.expectEqual(Severity.fatal, Severity.fatal3.getBaseLevel());
    try testing.expectEqual(Severity.invalid, Severity.invalid.getBaseLevel());
}

test "Severity from number" {
    const testing = std.testing;

    try testing.expectEqual(Severity.invalid, try fromNumber(0));
    try testing.expectEqual(Severity.trace, try fromNumber(1));
    try testing.expectEqual(Severity.debug, try fromNumber(5));
    try testing.expectEqual(Severity.info, try fromNumber(9));
    try testing.expectEqual(Severity.warn, try fromNumber(13));
    try testing.expectEqual(Severity.@"error", try fromNumber(17));
    try testing.expectEqual(Severity.fatal, try fromNumber(21));
    try testing.expectEqual(Severity.fatal4, try fromNumber(24));

    try testing.expectError(error.InvalidSeverityNumber, fromNumber(25));
    try testing.expectError(error.InvalidSeverityNumber, fromNumber(100));
    try testing.expectError(error.InvalidSeverityNumber, fromNumber(255));
}

test "Severity from text" {
    const testing = std.testing;

    // Exact matches
    try testing.expectEqual(Severity.invalid, try fromText("INVALID"));
    try testing.expectEqual(Severity.trace, try fromText("TRACE"));
    try testing.expectEqual(Severity.debug2, try fromText("DEBUG2"));
    try testing.expectEqual(Severity.info3, try fromText("INFO3"));
    try testing.expectEqual(Severity.warn4, try fromText("WARN4"));
    try testing.expectEqual(Severity.@"error", try fromText("ERROR"));
    try testing.expectEqual(Severity.fatal2, try fromText("FATAL2"));

    // Case insensitive
    try testing.expectEqual(Severity.trace, try fromText("trace"));
    try testing.expectEqual(Severity.debug, try fromText("Debug"));
    try testing.expectEqual(Severity.info, try fromText("iNfO"));
    try testing.expectEqual(Severity.fatal4, try fromText("fatal4"));

    // Short forms
    try testing.expectEqual(Severity.warn, try fromText("warn"));
    try testing.expectEqual(Severity.@"error", try fromText("error"));

    // Invalid text
    try testing.expectError(error.InvalidSeverityText, fromText("INVALID_SEVERITY"));
    try testing.expectError(error.InvalidSeverityText, fromText("TRACE5"));
    try testing.expectError(error.InvalidSeverityText, fromText(""));
    try testing.expectError(error.InvalidSeverityText, fromText("NOT_A_SEVERITY"));
}

test "Severity formatting" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;

    const result1 = try std.fmt.bufPrint(&buf, "{f}", .{Severity.@"error"});
    try testing.expectEqualStrings("ERROR", result1);

    const result2 = try std.fmt.bufPrint(&buf, "{f}", .{Severity.debug3});
    try testing.expectEqualStrings("DEBUG3", result2);

    const result3 = try std.fmt.bufPrint(&buf, "Severity: {f}", .{Severity.info});
    try testing.expectEqualStrings("Severity: INFO", result3);
}
