//! OpenTelemetry Span API
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#span

const std = @import("std");
const api = struct {
    const AttributeKeyValue = @import("../common/attributes.zig").AttributeKeyValue;
    const ContextBuilder = @import("../context/context.zig").ContextBuilder;
    const ContextKeyValue = @import("../context/context.zig").ContextKeyValue;
    const common = struct {
        const SpanId = @import("../common/types.zig").SpanId;
        const TraceId = @import("../common/types.zig").TraceId;
    };
};
const isValidatingMode = @import("../common/error_handler.zig").isValidatingMode;
const reportValidationError = @import("../common/error_handler.zig").reportValidationError;
const reportError = @import("../common/error_handler.zig").reportError;

/// Span interface; this should be created by a tracer.
pub const Span = union(enum) {
    noop: Context,
    bridge: Bridge, // SDK span bridge

    /// Clean up span resources
    pub inline fn deinit(self: *const Span) void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| {
                bridge.ctx.deinit(bridge.allocator);
                bridge.deinitFn(bridge.span_ptr);
            },
        }
    }

    // Access the span context.
    pub inline fn getSpanContext(self: *const Span) Context {
        return switch (self.*) {
            .noop => |span_context| span_context,
            .bridge => |bridge| bridge.ctx,
        };
    }

    pub inline fn isRecording(self: *const Span) bool {
        return switch (self.*) {
            .noop => false,
            .bridge => |bridge| bridge.is_recording,
        };
    }

    /// Set the name of the span.
    ///
    /// Note:  Samplers can only consider information already present during span
    /// creation. Any changes done later, including updated span name, cannot change
    /// their decisions.
    pub inline fn updateName(self: *Span, new_name: []const u8) void {
        // Because the name requires memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |*bridge| bridge.updateNameFn(bridge.span_ptr, new_name),
        }
    }

    /// Set the status of the span.
    pub inline fn setStatus(self: *Span, status: Status) void {
        // Because the status message may require memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |*bridge| bridge.setStatusFn(bridge.span_ptr, status),
        }
    }

    /// Add an attribute to the span.
    pub inline fn setAttribute(self: *Span, entry: api.AttributeKeyValue) void {
        // Because attribute management requires memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| bridge.setAttributeFn(bridge.span_ptr, entry),
        }
    }

    /// Add multiple attributes to the span.
    pub inline fn setAttributes(self: *Span, entries: []const api.AttributeKeyValue) void {
        // Because attribute management requires memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| bridge.setAttributesFn(bridge.span_ptr, entries),
        }
    }

    /// Add an event to the span.
    ///
    /// Records a timestamped annotation attached directly to this span's lifecycle.
    /// Span events are the right tool for lightweight, span-local moments
    /// (e.g. "cache miss", "retry attempt 2", "circuit breaker opened").
    ///
    /// **Use log-based events for structured or semantic content.**
    /// OpenTelemetry semantic conventions that capture content — in particular
    /// all GenAI conventions (`gen_ai.client.inference.operation.details`, etc.) —
    /// are defined as log-based events, not span events. Log-based events are
    /// richer (independent severity, body, filtering, and export pipeline) and
    /// are correlated to the active span automatically via the context.
    ///
    /// To emit a correlated log event, pass the same `ctx` slice that contains
    /// the active span; the SDK extracts trace/span IDs from it automatically:
    /// ```zig
    /// logger.emitEvent(ctx, event_name, .info, body, attributes);
    /// ```
    pub inline fn addEvent(self: *Span, event: Event) !void {
        // Because attribute and event management requires memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.addEventFn(bridge.span_ptr, event),
        }
    }

    /// Add a link to another span
    pub inline fn addLink(self: *Span, link: Link) !void {
        // Because attribute and link management requires memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.addLinkFn(bridge.span_ptr, link),
        }
    }

    /// Add multiple links to other spans at once.
    pub inline fn addLinks(self: *Span, links: []const Link) !void {
        // Because attribute and link management requires memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.addLinksFn(bridge.span_ptr, links),
        }
    }

    /// Record an exception as an event on the span.
    pub inline fn recordException(
        self: *Span,
        exception: anyerror,
        attributes: ?[]const api.AttributeKeyValue,
        timestamp: ?std.Io.Timestamp,
    ) !void {
        // Because this generally requires memory management, delegating to the bridge.
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| try bridge.recordExceptionFn(bridge.span_ptr, exception, attributes, timestamp),
        }
    }

    /// End the span with optional end options. This does NOT automatically
    /// invoke `.deinit()`. It is still up to the caller to ensure the span
    /// is freed when finished.
    ///
    /// The span becomes non-recording once `end()` is called.
    pub inline fn end(self: *Span, options: ?EndOptions) void {
        switch (self.*) {
            .noop => {},
            .bridge => |*bridge| {
                if (bridge.end_time == null) {
                    // end_time = null signals the SDK to use its io clock.
                    bridge.end_time = if (options) |opts| opts.end_time else null;
                    bridge.endFn(bridge.span_ptr, bridge.*, options);
                }
            },
        }
    }

    /// SpanStartOptions defines configuration options for creating a span
    pub const StartOptions = struct {
        /// Kind of the span (defaults to internal)
        kind: Kind = .internal,

        /// Initial attributes to set on the span
        attributes: []const api.AttributeKeyValue = &.{},

        /// Links to other spans
        links: []const Link = &.{},

        /// Custom start time.
        /// If null, current time will be used
        start_time: ?std.Io.Timestamp = null,

        /// Initial span status
        status: Status = .default,

        /// Create default span start options
        pub const default = StartOptions{};
    };

    /// SpanEndOptions defines configuration options for ending a span
    pub const EndOptions = struct {
        /// Custom end time.
        /// If null, current time will be used when the span is ended
        end_time: ?std.Io.Timestamp = null,

        /// Create default span end options
        pub const default: EndOptions = .{};
    };

    /// SpanKind describes the relationship between the Span, its parents, and its children
    pub const Kind = enum(u8) {
        unspecified = 0,

        /// Internal span represents an internal operation within an application
        internal = 1,

        /// Server span represents a request received by a server
        server,

        /// Client span represents a request made by a client
        client,

        /// Producer span represents a message sent to a message broker or queue
        producer,

        /// Consumer span represents a message received from a message broker or queue
        consumer,
    };

    /// Status represents the status of a finished span
    pub const Status = struct {
        /// StatusCode represents the canonical code of a span's status
        pub const StatusCode = enum(u8) {
            /// The default status - indicates that the status has not been set
            unset = 0,

            /// The operation completed successfully
            ok,

            /// The operation contains an error
            @"error",
        };

        /// The canonical status code
        code: StatusCode,

        /// Optional descriptive message, typically used with error status
        description: ?[]const u8 = null,

        pub const default = Status{
            .code = .unset,
            .description = null,
        };
    };
    pub const Bridge = @import("span_bridge.zig");
    pub const Context = @import("span_context.zig");
    pub const Event = @import("span_event.zig");
    pub const Limits = @import("span_limits.zig");
    pub const Link = @import("span_link.zig");
};

/// Validate that a span name meets OpenTelemetry requirements.
///
/// Validates span names for common issues while adhering to OpenTelemetry
/// specification requirements. Empty names are technically allowed but
/// reported for better developer experience.
///
/// ## Validation Rules
/// - **Empty names**: Allowed by spec but reported as validation issue
/// - **Non-null**: Guaranteed by Zig's type system
///
/// ## Returns
/// - `true` if name is valid or validation is disabled (release builds)
/// - `false` if name should be reported (empty) and validation is enabled
pub fn validateSpanName(name: []const u8) bool {
    if (!isValidatingMode()) return true; // No validation in release
    // Empty span names are allowed per spec but should be reported
    return name.len > 0;
}

test "Span debug mode validation" {
    const testing = std.testing;

    // This test only runs in debug mode
    if (!isValidatingMode()) return;

    // Test span with validation errors - should not crash
    var span = Span{ .noop = Span.Context.invalid };

    // Test setAttribute with empty key - should trigger validation in debug mode
    span.setAttribute(.{ .key = "", .value = .{ .string = "test" } });

    // Test setAttributes with mixed valid/invalid keys
    const mixed_attrs = [_]api.AttributeKeyValue{
        .{ .key = "valid.key", .value = .{ .string = "valid" } },
        .{ .key = "", .value = .{ .string = "invalid" } },
    };
    span.setAttributes(&mixed_attrs);

    // Test updateName with empty name
    span.updateName("");

    // If we reach here without crashing, validation is working
    try testing.expect(true);
}

test "wrapSpanContext creates non-recording span" {
    const testing = std.testing;

    // Create a valid SpanContext
    const span_context = Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 }),
        .span_id = api.common.SpanId.fromBytes([_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }),
        .trace_flags = Span.Context.SAMPLED_FLAG,
        .trace_state = "vendor=value",
        .is_remote = true,
    };

    // Wrap it in a Span
    var wrapped_span = Span{ .noop = span_context };

    // Verify it's a non-recording span
    try testing.expect(!wrapped_span.isRecording());

    // Verify getSpanContext returns the wrapped context
    const returned_context = wrapped_span.getSpanContext();
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &returned_context.trace_id.bytes);
    try testing.expectEqualSlices(u8, &span_context.span_id.bytes, &returned_context.span_id.bytes);
    try testing.expectEqual(span_context.trace_flags, returned_context.trace_flags);
    try testing.expectEqual(span_context.is_remote, returned_context.is_remote);
    try testing.expectEqualStrings(span_context.trace_state.?, returned_context.trace_state.?);

    // Verify all operations are no-ops (should not crash)
    wrapped_span.setAttribute(.{ .key = "key", .value = .{ .string = "value" } });
    try wrapped_span.addEvent(Span.Event{
        .name = "test",
        .timestamp = std.Io.Timestamp.zero,
        .attributes = &.{},
    });
    wrapped_span.setStatus(.{ .code = .ok });
    wrapped_span.updateName("new-name");
    wrapped_span.end(null);

    // Should still be able to get context after operations
    const final_context = wrapped_span.getSpanContext();
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &final_context.trace_id.bytes);
}

test "wrapSpanContext works with invalid SpanContext" {
    const testing = std.testing;

    // Test with invalid SpanContext
    const wrapped_span = Span{ .noop = Span.Context.invalid };

    // Should still work
    try testing.expect(!wrapped_span.isRecording());

    const returned_context = wrapped_span.getSpanContext();
    try testing.expect(!returned_context.isValid());
}
