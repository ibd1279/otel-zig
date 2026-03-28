//! OpenTelemetry Log Record API
//!
//! This module defines the LogRecord structure according to the OpenTelemetry specification.
//! A LogRecord represents a single log entry with associated metadata.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/data-model.md

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
};

/// LogRecord represents a log entry according to the OpenTelemetry specification.
/// This is a non-owning structure - all slices reference external memory.
///
/// Required fields according to the spec:
/// - timestamp (here as timestamp_ns)
/// - observed_timestamp (here as observed_timestamp_ns)
/// - severity_number
/// - body
///
/// Optional fields:
/// - severity_text
/// - attributes
/// - trace_id
/// - span_id
/// - flags
pub const LogRecord = struct {
    /// Time when the event occurred.
    timestamp: ?std.Io.Timestamp = null,

    /// Time when the event was observed.
    /// If not set, it should be set to the current time when the record is emitted.
    observed_timestamp: ?std.Io.Timestamp = null,

    /// Numeric severity level
    severity_number: api.logs.Severity = .invalid,

    /// Human-readable severity text (optional)
    severity_text: ?[]const u8 = null,

    /// The log message body
    body: ?api.common.AttributeValue = null,

    /// Name that identifies the class/type of the event
    /// A log record with a non-empty event name is an Event according to OpenTelemetry spec
    event_name: ?[]const u8 = null,

    /// Additional attributes associated with the log record
    attributes: []const api.AttributeKeyValue = &[_]api.AttributeKeyValue{},

    /// TraceId of the span that this log record is associated with
    trace_id: ?api.common.TraceId = null,

    /// SpanId of the span that this log record is associated with
    span_id: ?api.common.SpanId = null,

    /// Trace flags (1 byte)
    flags: ?u8 = null,

    /// Instrumentation scope that produced this log record.
    instrumentation_scope: ?api.InstrumentationScope = null,

    /// Check if this log record is associated with a trace
    pub inline fn hasTraceContext(self: *const LogRecord) bool {
        return self.trace_id != null and self.span_id != null;
    }

    /// Get the severity number as an integer
    pub inline fn severityNumber(self: *const LogRecord) i32 {
        return @intFromEnum(self.severity_number);
    }

    /// Deep copy a LogRecord. Must call `deinitOwned` on the return instance.
    /// Only clones the fields that reference external memory: severity_text, body, event_name, and attributes.
    /// All other fields are copied by value.
    pub fn initOwned(allocator: std.mem.Allocator, record: LogRecord) !LogRecord {
        var owned = LogRecord{
            .timestamp = record.timestamp,
            .observed_timestamp = record.observed_timestamp,
            .severity_number = record.severity_number,
            .trace_id = record.trace_id,
            .span_id = record.span_id,
            .flags = record.flags,
            .instrumentation_scope = record.instrumentation_scope,
        };

        // Clone severity_text if present
        if (record.severity_text) |text| {
            owned.severity_text = try allocator.dupe(u8, text);
        }

        // Clone event_name if present
        if (record.event_name) |name| {
            owned.event_name = try allocator.dupe(u8, name);
        }

        // Clone body if present
        if (record.body) |body| {
            owned.body = try body.initOwned(allocator);
        }

        // Clone attributes
        owned.attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, record.attributes);

        return owned;
    }

    /// Destroy a deep copied LogRecord.
    pub fn deinitOwned(self: LogRecord, allocator: std.mem.Allocator) void {
        if (self.severity_text) |text| {
            allocator.free(text);
        }
        if (self.event_name) |name| {
            allocator.free(name);
        }
        if (self.body) |body| {
            body.deinitOwned(allocator);
        }
        api.AttributeKeyValue.deinitOwnedSlice(allocator, self.attributes);
    }
};

test "LogRecord initOwned and deinitOwned" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create attributes for testing
    const attributes = try api.common.AttributeBuilder.init(allocator)
        .add(.{ .key = "test.key", .value = .{ .string = "test.value" } })
        .add(.{ .key = "count", .value = .{ .int = 42 } })
        .finish(allocator);
    defer api.AttributeKeyValue.deinitOwnedSlice(allocator, attributes);

    // Create original log record with all possible fields
    const original = LogRecord{
        .timestamp = std.Io.Timestamp.fromNanoseconds(1234567890),
        .observed_timestamp = std.Io.Timestamp.fromNanoseconds(1234567891),
        .severity_number = .info,
        .severity_text = "INFO",
        .body = .{ .string = "Test message" },
        .event_name = "test.event",
        .attributes = attributes,
        .trace_id = api.common.TraceId.fromBytes([_]u8{1} ++ [_]u8{0} ** 15),
        .span_id = api.common.SpanId.fromBytes([_]u8{2} ++ [_]u8{0} ** 7),
        .flags = 0x01,
    };

    // Create owned copy
    const owned = try LogRecord.initOwned(allocator, original);
    defer owned.deinitOwned(allocator);

    // Verify all fields are copied correctly
    try testing.expectEqual(original.timestamp, owned.timestamp);
    try testing.expectEqual(original.observed_timestamp, owned.observed_timestamp);
    try testing.expectEqual(original.severity_number, owned.severity_number);
    try testing.expectEqual(original.trace_id, owned.trace_id);
    try testing.expectEqual(original.span_id, owned.span_id);
    try testing.expectEqual(original.flags, owned.flags);

    // Verify string fields are deep copied
    try testing.expectEqualStrings("INFO", owned.severity_text.?);
    try testing.expectEqualStrings("test.event", owned.event_name.?);
    try testing.expectEqualStrings("Test message", owned.body.?.string);

    // Verify attributes are deep copied
    try testing.expect(original.attributes.ptr != owned.attributes.ptr);
    try testing.expectEqual(@as(usize, 2), owned.attributes.len);
    try testing.expectEqualStrings("test.key", owned.attributes[0].key);
    try testing.expectEqualStrings("test.value", owned.attributes[0].value.string);
    try testing.expectEqualStrings("count", owned.attributes[1].key);
    try testing.expectEqual(@as(i64, 42), owned.attributes[1].value.int);

    // Verify that the owned copy has different memory addresses for strings
    try testing.expect(original.severity_text.?.ptr != owned.severity_text.?.ptr);
    try testing.expect(original.event_name.?.ptr != owned.event_name.?.ptr);
    try testing.expect(original.body.?.string.ptr != owned.body.?.string.ptr);
}
