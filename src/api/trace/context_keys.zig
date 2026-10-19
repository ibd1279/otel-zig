//! OpenTelemetry Trace Context Keys
//!
//! This module defines context keys for trace-specific data that can be stored
//! in OpenTelemetry contexts. These keys provide type-safe access to trace
//! information across API boundaries.
//!
//! The keys follow the OpenTelemetry specification for trace context propagation
//! and integrate with the existing context system.

const std = @import("std");
const api = struct {
    const baggage = struct {
        const BaggageKeyValue = @import("../baggage/baggage.zig").BaggageKeyValue;
    };
    const common = struct {
        const TraceId = @import("../common/types.zig").TraceId;
        const SpanId = @import("../common/types.zig").SpanId;
    };
    const context = struct {
        const ContextKey = @import("../context/context_key.zig").ContextKey;
    };
    const trace = struct {
        const Span = @import("span.zig").Span;
    };
};

/// Context key for the currently active span context.
/// This represents the span that is currently executing in the local context.
pub const active_span_context_key = api.context.ContextKey(api.trace.Span.Context, "otel.trace.active_span_context");

/// Context key for remote span context extracted from carriers.
/// This is used to store span context that was extracted from incoming
/// requests or messages, typically from HTTP headers or message metadata.
pub const remote_span_context_key = api.context.ContextKey(api.trace.Span.Context, "otel.trace.remote_span_context");

/// Context key for trace-specific baggage.
/// This stores baggage key-value pairs that should be propagated
/// along with trace context across service boundaries.
pub const trace_baggage_key = api.context.ContextKey([]api.baggage.BaggageKeyValue, "otel.trace.baggage");

/// Context key for sampling decision.
/// This stores whether the current trace should be sampled, which
/// can be used by sampling strategies to make consistent decisions.
pub const sampling_decision_key = api.context.ContextKey(bool, "otel.trace.sampling_decision");

/// Context key for trace flags.
/// This stores the W3C trace flags that should be propagated
/// with the trace context.
pub const trace_flags_key = api.context.ContextKey(u8, "otel.trace.flags");

/// Context key for trace state.
/// This stores the W3C trace state string that carries vendor-specific
/// trace identification data.
pub const trace_state_key = api.context.ContextKey([]const u8, "otel.trace.state");

test "trace context keys have unique identifiers" {
    const testing = std.testing;

    // Ensure all keys have different IDs
    const key_ids = [_]u64{
        active_span_context_key.key_id,
        remote_span_context_key.key_id,
        trace_baggage_key.key_id,
        sampling_decision_key.key_id,
        trace_flags_key.key_id,
        trace_state_key.key_id,
    };

    for (key_ids, 0..) |id, i| {
        for (key_ids[i + 1 ..]) |other_id| {
            try testing.expect(id != other_id);
        }
    }
}

test "trace context keys have correct value types" {
    const testing = std.testing;

    // Test that keys have the expected value types
    try testing.expect(active_span_context_key.ValueType == api.trace.Span.Context);
    try testing.expect(remote_span_context_key.ValueType == api.trace.Span.Context);
    try testing.expect(trace_baggage_key.ValueType == []api.baggage.BaggageKeyValue);
    try testing.expect(sampling_decision_key.ValueType == bool);
    try testing.expect(trace_flags_key.ValueType == u8);
    try testing.expect(trace_state_key.ValueType == []const u8);
}

test "trace context keys have correct names" {
    const testing = std.testing;

    // Verify key names are correct
    try testing.expectEqualStrings("otel.trace.active_span_context", active_span_context_key.key_name);
    try testing.expectEqualStrings("otel.trace.remote_span_context", remote_span_context_key.key_name);
    try testing.expectEqualStrings("otel.trace.baggage", trace_baggage_key.key_name);
    try testing.expectEqualStrings("otel.trace.sampling_decision", sampling_decision_key.key_name);
    try testing.expectEqualStrings("otel.trace.flags", trace_flags_key.key_name);
    try testing.expectEqualStrings("otel.trace.state", trace_state_key.key_name);
}

test "context keys can wrap and unwrap values" {
    const testing = std.testing;

    // Test Span.Context key
    const span_ctx = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes(@splat(0x01)),
        .span_id = api.common.SpanId.fromBytes(@splat(0x02)),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    const wrapped_span = active_span_context_key.wrapValue(span_ctx);
    const unwrapped_span = active_span_context_key.unwrapValue(wrapped_span);
    try testing.expect(unwrapped_span != null);
    try testing.expectEqualSlices(u8, &span_ctx.trace_id.bytes, &unwrapped_span.?.trace_id.bytes);
    try testing.expectEqualSlices(u8, &span_ctx.span_id.bytes, &unwrapped_span.?.span_id.bytes);

    // Test sampling decision key
    const should_sample = true;
    const wrapped_decision = sampling_decision_key.wrapValue(should_sample);
    const unwrapped_decision = sampling_decision_key.unwrapValue(wrapped_decision);
    try testing.expect(unwrapped_decision != null);
    try testing.expectEqual(should_sample, unwrapped_decision.?);

    // Test trace flags key
    const flags: u8 = 0x01;
    const wrapped_flags = trace_flags_key.wrapValue(flags);
    const unwrapped_flags = trace_flags_key.unwrapValue(wrapped_flags);
    try testing.expect(unwrapped_flags != null);
    try testing.expectEqual(flags, unwrapped_flags.?);

    // Test trace state key
    const state: []const u8 = "vendor=value";
    const wrapped_state = trace_state_key.wrapValue(state);
    const unwrapped_state = trace_state_key.unwrapValue(wrapped_state);
    try testing.expect(unwrapped_state != null);
    try testing.expectEqualStrings(state, unwrapped_state.?);
}

test "context keys validate value types correctly" {
    const testing = std.testing;

    // Test correct type validation
    const span_ctx = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes(@splat(0x01)),
        .span_id = api.common.SpanId.fromBytes(@splat(0x02)),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };
    const span_value = active_span_context_key.wrapValue(span_ctx);
    try testing.expect(active_span_context_key.validateValue(span_value));

    const bool_value = sampling_decision_key.wrapValue(true);
    try testing.expect(sampling_decision_key.validateValue(bool_value));

    // Test incorrect type validation
    try testing.expect(!active_span_context_key.validateValue(bool_value));
    try testing.expect(!sampling_decision_key.validateValue(span_value));
}
