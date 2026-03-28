//! W3C Trace Context Propagator
//!
//! This module implements the W3C Trace Context specification for propagating
//! trace context across process boundaries via HTTP headers.
//!
//! The propagator handles the `traceparent` and `tracestate` headers according
//! to the W3C specification, enabling distributed tracing across services.
//!
//! See: https://www.w3.org/TR/trace-context/

const std = @import("std");
const api = struct {
    const ContextBuilder = @import("../context/context.zig").ContextBuilder;
    const ContextKeyValue = @import("../context/context.zig").ContextKeyValue;
    const common = struct {
        const TraceId = @import("../common/types.zig").TraceId;
        const SpanId = @import("../common/types.zig").SpanId;
    };
    const trace = struct {
        const Span = @import("span.zig").Span;
    };
};
const TextMapCarrier = @import("../context/propagation.zig").TextMapCarrier;
const TextMapPropagator = @import("../context/propagation.zig").TextMapPropagator;
const context_keys = @import("context_keys.zig");

/// W3C Trace Context field names
pub const TRACEPARENT_HEADER = "traceparent";
pub const TRACESTATE_HEADER = "tracestate";

/// W3C Trace Context version (currently only version 00 is supported)
pub const SUPPORTED_VERSION: u8 = 0x00;

/// W3C Trace Context propagator implementation
pub const W3cPropagator = struct {
    /// Initialize a new W3C propagator
    pub fn init() W3cPropagator {
        return .{};
    }

    /// Inject trace context into a carrier
    pub fn inject(self: *const W3cPropagator, ctx: []const api.ContextKeyValue, carrier: *TextMapCarrier) void {
        _ = self;

        // Get the active span context from the context
        const span_context_entry = api.ContextKeyValue.scanSlice(ctx, context_keys.active_span_context_key) orelse return;
        const span_context = context_keys.active_span_context_key.unwrapValue(span_context_entry.value) orelse return;

        // Only inject if the span context is valid
        if (!span_context.isValid()) return;

        // Generate traceparent header
        var traceparent_buf: [55]u8 = undefined; // "00-" + 32 + "-" + 16 + "-" + 2 = 55
        const traceparent = formatTraceparent(span_context, &traceparent_buf);
        carrier.set(TRACEPARENT_HEADER, traceparent);

        // Inject tracestate if present
        if (span_context.trace_state) |state| {
            if (state.len > 0) {
                carrier.set(TRACESTATE_HEADER, state);
            }
        }
    }

    /// Extract trace context from a carrier
    pub fn extract(
        self: *const W3cPropagator,
        allocator: std.mem.Allocator,
        ctx: []const api.ContextKeyValue,
        carrier: *const TextMapCarrier,
    ) ![]api.ContextKeyValue {
        _ = self;

        const ctx_builder = api.ContextBuilder.init(allocator)
            .addMany(ctx);
        errdefer ctx_builder.deinit();

        // Try to extract traceparent header
        const traceparent_header = carrier.get(TRACEPARENT_HEADER) orelse return try ctx_builder.finish(allocator);

        // Parse the traceparent header
        const span_context = parseTraceparent(traceparent_header) catch
            return try ctx_builder.finish(allocator); // Return original context on parse failure

        // Extract tracestate if present
        const trace_state = carrier.get(TRACESTATE_HEADER);
        const final_span_context = if (trace_state) |state|
            span_context.withTraceState(state).asRemote()
        else
            span_context.asRemote();

        // Store the extracted span context in the new context
        return ctx_builder
            .add(.{ .key = context_keys.remote_span_context_key.key_id, .value = .{ .span_context = final_span_context } })
            .finish(allocator);
    }

    /// Get the fields that this propagator uses
    pub fn fields(self: *const W3cPropagator, allocator: std.mem.Allocator) ![]const []const u8 {
        _ = self;
        const field_list = try allocator.alloc([]const u8, 2);
        field_list[0] = TRACEPARENT_HEADER;
        field_list[1] = TRACESTATE_HEADER;
        return field_list;
    }
};

/// Format a SpanContext into a W3C traceparent header value
fn formatTraceparent(span_context: api.trace.Span.Context, buf: *[55]u8) []const u8 {
    var trace_hex_buf: [32]u8 = undefined;
    var span_hex_buf: [16]u8 = undefined;

    const trace_hex = span_context.traceIdHex(&trace_hex_buf);
    const span_hex = span_context.spanIdHex(&span_hex_buf);

    const result = std.fmt.bufPrint(buf, "{x:0>2}-{s}-{s}-{x:0>2}", .{
        SUPPORTED_VERSION,
        trace_hex,
        span_hex,
        span_context.trace_flags,
    }) catch unreachable; // Buffer is sized correctly

    return result;
}

/// Parse a W3C traceparent header value into a SpanContext
fn parseTraceparent(traceparent: []const u8) !api.trace.Span.Context {
    // Validate minimum length: "00-{32}-{16}-00" = 55 characters
    if (traceparent.len < 55) return error.InvalidTraceparent;

    // Check that we have exactly 4 parts separated by hyphens
    var parts = std.mem.splitScalar(u8, traceparent, '-');
    const version_str = parts.next() orelse return error.InvalidTraceparent;
    const trace_id_str = parts.next() orelse return error.InvalidTraceparent;
    const span_id_str = parts.next() orelse return error.InvalidTraceparent;
    const flags_str = parts.next() orelse return error.InvalidTraceparent;

    // Ensure no extra parts
    if (parts.next() != null) return error.InvalidTraceparent;

    // Parse version (must be 00 for now)
    if (version_str.len != 2) return error.InvalidTraceparent;
    const version = std.fmt.parseInt(u8, version_str, 16) catch return error.InvalidTraceparent;
    if (version != SUPPORTED_VERSION) return error.InvalidTraceparent;

    // Parse trace ID (32 hex characters)
    if (trace_id_str.len != 32) return error.InvalidTraceparent;
    const trace_id = (api.trace.Span.Context.parseTraceId(trace_id_str) catch return error.InvalidTraceparent) orelse return error.InvalidTraceparent;

    // Parse span ID (16 hex characters)
    if (span_id_str.len != 16) return error.InvalidTraceparent;
    const span_id = (api.trace.Span.Context.parseSpanId(span_id_str) catch return error.InvalidTraceparent) orelse return error.InvalidTraceparent;

    // Parse flags (2 hex characters)
    if (flags_str.len != 2) return error.InvalidTraceparent;
    const flags = std.fmt.parseInt(u8, flags_str, 16) catch return error.InvalidTraceparent;

    return api.trace.Span.Context{
        .trace_id = trace_id,
        .span_id = span_id,
        .trace_flags = flags,
        .trace_state = null, // Will be set separately if tracestate header exists
        .is_remote = false, // Will be set to true by extract()
    };
}

/// Extract a remote SpanContext from raw traceparent/tracestate header values.
///
/// Returns null when traceparent is absent or malformed — callers can treat
/// null as "no parent" and start a root span.  This is the low-level helper
/// for frameworks that have already fetched the header strings; use
/// W3cPropagator.extract() when working with a TextMapCarrier instead.
pub fn spanContextFromHeaders(
    traceparent: ?[]const u8,
    tracestate: ?[]const u8,
) ?api.trace.Span.Context {
    const tp = traceparent orelse return null;
    const sc = parseTraceparent(tp) catch return null;
    return if (tracestate) |ts| sc.withTraceState(ts).asRemote() else sc.asRemote();
}

/// Create a W3C propagator instance wrapped in TextMapPropagator
pub fn createW3cPropagator() TextMapPropagator {
    return .{ .w3c = W3cPropagator.init() };
}

// ============================================================================
// Tests
// ============================================================================

test "W3cPropagator formatTraceparent" {
    const testing = std.testing;

    const span_context = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 }),
        .span_id = api.common.SpanId.fromBytes([_]u8{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 }),
        .trace_flags = 0x01,
        .trace_state = null,
        .is_remote = false,
    };

    var buf: [55]u8 = undefined;
    const traceparent = formatTraceparent(span_context, &buf);

    try testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", traceparent);
}

test "W3cPropagator parseTraceparent valid" {
    const testing = std.testing;

    const traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const span_context = try parseTraceparent(traceparent);

    try testing.expect(span_context.isValid());
    try testing.expectEqual(@as(u8, 0x4b), span_context.trace_id.bytes[0]);
    try testing.expectEqual(@as(u8, 0x36), span_context.trace_id.bytes[15]);
    try testing.expectEqual(@as(u8, 0x00), span_context.span_id.bytes[0]);
    try testing.expectEqual(@as(u8, 0xb7), span_context.span_id.bytes[7]);
    try testing.expectEqual(@as(u8, 0x01), span_context.trace_flags);
    try testing.expect(span_context.isSampled());
}

test "W3cPropagator parseTraceparent invalid cases" {
    const testing = std.testing;

    // Too short
    try testing.expectError(error.InvalidTraceparent, parseTraceparent("00-4bf92f35-00f067aa-01"));

    // Wrong version
    try testing.expectError(error.InvalidTraceparent, parseTraceparent("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"));

    // Invalid trace ID (all zeros)
    try testing.expectError(error.InvalidTraceparent, parseTraceparent("00-00000000000000000000000000000000-00f067aa0ba902b7-01"));

    // Invalid span ID (all zeros)
    try testing.expectError(error.InvalidTraceparent, parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"));

    // Too many parts
    try testing.expectError(error.InvalidTraceparent, parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra"));

    // Non-hex characters
    try testing.expectError(error.InvalidTraceparent, parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e47zz-00f067aa0ba902b7-01"));
}

test "W3cPropagator inject and extract" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a test span context
    const span_context = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 }),
        .span_id = api.common.SpanId.fromBytes([_]u8{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 }),
        .trace_flags = 0x01,
        .trace_state = "vendor=value",
        .is_remote = false,
    };

    // Create context with active span
    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const ctx_with_span = try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = context_keys.active_span_context_key.key_id, .value = .{ .span_context = span_context } })
        .finish(allocator);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_span);

    // Create propagator and carrier
    const propagator = W3cPropagator.init();
    var hash_carrier = @import("../context/propagation.zig").HashMapCarrier.init(allocator);
    defer hash_carrier.deinit();
    var carrier = hash_carrier.carrier();

    // Inject context
    propagator.inject(ctx_with_span, &carrier);

    // Check injected headers
    const traceparent = carrier.get(TRACEPARENT_HEADER);
    try testing.expect(traceparent != null);
    try testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", traceparent.?);

    const tracestate = carrier.get(TRACESTATE_HEADER);
    try testing.expect(tracestate != null);
    try testing.expectEqualStrings("vendor=value", tracestate.?);

    // Extract context
    const empty_ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, empty_ctx);

    const extracted_ctx = try propagator.extract(allocator, empty_ctx, &carrier);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, extracted_ctx);

    // Verify extracted span context
    const maybe_extracted_span = api.ContextKeyValue.scanSlice(extracted_ctx, context_keys.remote_span_context_key) orelse null;
    const extracted_span = if (maybe_extracted_span) |kv| context_keys.remote_span_context_key.unwrapValue(kv.value) else null;
    try testing.expect(extracted_span != null);
    try testing.expect(extracted_span.?.isValid());
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &extracted_span.?.trace_id.bytes);
    try testing.expectEqualSlices(u8, &span_context.span_id.bytes, &extracted_span.?.span_id.bytes);
    try testing.expectEqual(span_context.trace_flags, extracted_span.?.trace_flags);
    try testing.expect(extracted_span.?.is_remote);
    try testing.expectEqualStrings("vendor=value", extracted_span.?.trace_state.?);
}

test "W3cPropagator extract without headers returns original context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const propagator = W3cPropagator.init();
    var hash_carrier = @import("../context/propagation.zig").HashMapCarrier.init(allocator);
    defer hash_carrier.deinit();
    var carrier = hash_carrier.carrier();

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const result_ctx = try propagator.extract(allocator, ctx, &carrier);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, result_ctx);

    // Should return context without remote span context
    try testing.expect(api.ContextKeyValue.scanSlice(result_ctx, context_keys.remote_span_context_key) == null);
}

test "W3cPropagator fields" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const propagator = W3cPropagator.init();
    const field_list = try propagator.fields(allocator);
    defer allocator.free(field_list);

    try testing.expectEqual(@as(usize, 2), field_list.len);
    try testing.expectEqualStrings(TRACEPARENT_HEADER, field_list[0]);
    try testing.expectEqualStrings(TRACESTATE_HEADER, field_list[1]);
}

test "W3cPropagator inject with invalid span context does nothing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create context with invalid span context
    const invalid_span = api.trace.Span.Context.invalid;
    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const ctx_with_span = try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = context_keys.active_span_context_key.key_id, .value = .{ .span_context = invalid_span } })
        .finish(allocator);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_span);

    // Inject should do nothing
    const propagator = W3cPropagator.init();
    var hash_carrier = @import("../context/propagation.zig").HashMapCarrier.init(allocator);
    defer hash_carrier.deinit();
    var carrier = hash_carrier.carrier();

    propagator.inject(ctx_with_span, &carrier);

    // Verify no headers were set
    try testing.expect(carrier.get(TRACEPARENT_HEADER) == null);
    try testing.expect(carrier.get(TRACESTATE_HEADER) == null);
}
