//! Common types for OpenTelemetry in Zig
//!
//! This module contains shared type definitions used across different telemetry signals.
//! Note: ID generation logic is handled in the tracing module, while these types
//! provide consistent definitions for ID representation and manipulation.

const std = @import("std");

/// TraceId represents a unique identifier for a trace.
/// As per OpenTelemetry specification, it is 16 bytes (128 bits).
fn ByteId(byte_length: comptime_int) type {
    return struct {
        const Self = @This();
        pub const length = byte_length;
        bytes: [length]u8,

        /// Creates a new TraceId from a byte array
        pub fn fromBytes(bytes: [length]u8) Self {
            return .{ .bytes = bytes };
        }

        /// Returns true if the TraceId is invalid (all zeros)
        pub fn isInvalid(self: Self) bool {
            for (self.bytes) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }

        /// Returns true if the TraceId is valid (not all zeros)
        pub fn isValid(self: Self) bool {
            return !self.isInvalid();
        }

        /// Formats the TraceId as a hex string
        pub fn format(
            self: Self,
            writer: anytype,
        ) !void {
            for (self.bytes) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        }

        /// Creates a TraceId from a hex string
        pub fn fromHexString(hex: []const u8) !Self {
            if (hex.len != length * 2) return error.invalid_length;

            var bytes: [length]u8 = undefined;
            for (0..length) |i| {
                bytes[i] = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
            }
            return .{ .bytes = bytes };
        }

        pub fn toHexString(self: Self, buffer: *[length * 2]u8) void {
            buffer.* = std.fmt.bytesToHex(&self.bytes, .lower);
        }
    };
}

pub const TraceId = ByteId(16);
pub const SpanId = ByteId(8);

test "TraceId validity checks" {
    const testing = std.testing;

    // Test invalid TraceId (all zeros)
    const invalid_trace_id = TraceId{ .bytes = @splat(0) };
    try testing.expect(invalid_trace_id.isInvalid());
    try testing.expect(!invalid_trace_id.isValid());

    // Test valid TraceId
    var valid_bytes: [16]u8 = @splat(0);
    valid_bytes[0] = 1;
    const valid_trace_id = TraceId{ .bytes = valid_bytes };
    try testing.expect(!valid_trace_id.isInvalid());
    try testing.expect(valid_trace_id.isValid());
}

test "SpanId validity checks" {
    const testing = std.testing;

    // Test invalid SpanId (all zeros)
    const invalid_span_id = SpanId{ .bytes = @splat(0) };
    try testing.expect(invalid_span_id.isInvalid());
    try testing.expect(!invalid_span_id.isValid());

    // Test valid SpanId
    var valid_bytes: [8]u8 = @splat(0);
    valid_bytes[0] = 1;
    const valid_span_id = SpanId{ .bytes = valid_bytes };
    try testing.expect(!valid_span_id.isInvalid());
    try testing.expect(valid_span_id.isValid());
}

test "TraceId hex string conversion" {
    const testing = std.testing;

    const hex_string = "0123456789abcdef0123456789abcdef";
    const trace_id = try TraceId.fromHexString(hex_string);

    var buffer: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{f}", .{trace_id});
    try testing.expectEqualStrings(hex_string, formatted);
}

test "SpanId hex string conversion" {
    const testing = std.testing;

    const hex_string = "0123456789abcdef";
    const span_id = try SpanId.fromHexString(hex_string);

    var buffer: [16]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{f}", .{span_id});
    try testing.expectEqualStrings(hex_string, formatted);
}

// Validation functions for use by SDK implementations
const isValidatingMode = @import("error_handler.zig").isValidatingMode;
const reportValidationError = @import("error_handler.zig").reportValidationError;

/// Validate trace ID in debug mode
pub fn validateTraceId(trace_id: ?TraceId) ?TraceId {
    if (!isValidatingMode()) return trace_id;

    if (trace_id) |id| {
        if (id.isInvalid()) {
            reportValidationError(.logger, "emitLogRecord", "Invalid all-zero trace ID provided", null);
        }
    }
    return trace_id;
}

/// Validate span ID in debug mode
pub fn validateSpanId(span_id: ?SpanId) ?SpanId {
    if (!isValidatingMode()) return span_id;

    if (span_id) |id| {
        if (id.isInvalid()) {
            reportValidationError(.logger, "emitLogRecord", "Invalid all-zero span ID provided", null);
        }
    }
    return span_id;
}

/// Validate trace flags in debug mode
pub fn validateTraceFlags(flags: ?u8) ?u8 {
    if (!isValidatingMode()) return flags;

    if (flags) |f| {
        // Currently all 8 bits are allowed per W3C trace context spec
        // This validation is here for future extensibility
        const DEFINED_FLAGS_MASK: u8 = 0xFF;
        if (f & ~DEFINED_FLAGS_MASK != 0) {
            reportValidationError(.logger, "emitLogRecord", "Invalid trace flags with undefined bits set", null);
        }
    }
    return flags;
}
