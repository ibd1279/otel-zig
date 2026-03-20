//! OpenTelemetry Trace Context Utilities
//!
//! This module provides utility functions for common trace context operations,
//! making it easier to work with trace contexts in OpenTelemetry applications.
//!
//! These utilities build on the existing context system and trace context keys
//! to provide convenient functions for typical trace context workflows.

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
const context_keys = @import("context_keys.zig");
const implicit = @import("../context/implicit.zig");

/// Get the active span context from a context, if present
pub fn getActiveSpanContext(ctx: []const api.ContextKeyValue) ?api.trace.Span.Context {
    return extractContextValue(ctx, context_keys.active_span_context_key);
}

/// Returns the active span from the implicit thread-local context.
/// Returns a noop span wrapping Span.Context.invalid if no span is active.
pub fn getActiveSpan() api.trace.Span {
    const span_ctx = getActiveSpanContext(implicit.getCurrent());
    return .{ .noop = span_ctx orelse api.trace.Span.Context.invalid };
}

/// Get the remote span context from a context, if present
pub fn getRemoteSpanContext(ctx: []const api.ContextKeyValue) ?api.trace.Span.Context {
    return extractContextValue(ctx, context_keys.remote_span_context_key);
}

/// Get any span context from a context, preferring active over remote
pub fn getSpanContext(ctx: []const api.ContextKeyValue) ?api.trace.Span.Context {
    return getActiveSpanContext(ctx) orelse getRemoteSpanContext(ctx);
}

/// Create a new context with the given span context as the active span
pub fn withActiveSpanContext(
    allocator: std.mem.Allocator,
    ctx: []const api.ContextKeyValue,
    span_context: api.trace.Span.Context,
) ![]api.ContextKeyValue {
    return ownedWithKeyValue(allocator, ctx, context_keys.active_span_context_key, span_context);
}

/// Create a new context with the given span context as a remote span
pub fn withRemoteSpanContext(
    allocator: std.mem.Allocator,
    ctx: []const api.ContextKeyValue,
    span_context: api.trace.Span.Context,
) ![]api.ContextKeyValue {
    return ownedWithKeyValue(allocator, ctx, context_keys.remote_span_context_key, span_context);
}

/// Create a child span context from a parent span context
pub fn createChildSpanContext(parent: api.trace.Span.Context, random: std.Random) api.trace.Span.Context {
    return api.trace.Span.Context.fromTraceId(parent.trace_id, random)
        .withTraceFlags(parent.trace_flags)
        .withTraceState(parent.trace_state);
}

/// Create a new root span context (new trace)
pub fn createRootSpanContext(random: std.Random) api.trace.Span.Context {
    return api.trace.Span.Context.generate(random);
}

/// Check if a context has any span context (active or remote)
pub fn hasSpanContext(ctx: []const api.ContextKeyValue) bool {
    return extractContextValue(ctx, context_keys.active_span_context_key) != null or
        extractContextValue(ctx, context_keys.remote_span_context_key) != null;
}

/// Check if a context has an active span context
pub fn hasActiveSpanContext(ctx: []const api.ContextKeyValue) bool {
    return extractContextValue(ctx, context_keys.active_span_context_key) != null;
}

/// Check if a context has a remote span context
pub fn hasRemoteSpanContext(ctx: []const api.ContextKeyValue) bool {
    return extractContextValue(ctx, context_keys.remote_span_context_key) != null;
}

/// Get the trace ID from the context, if any span context is present
pub fn getTraceId(ctx: []const api.ContextKeyValue) ?api.common.TraceId {
    const span_ctx = getSpanContext(ctx) orelse return null;
    return span_ctx.trace_id;
}

/// Get the span ID from the active span context, if present
pub fn getActiveSpanId(ctx: []const api.ContextKeyValue) ?api.common.SpanId {
    const span_ctx = getActiveSpanContext(ctx) orelse return null;
    return span_ctx.span_id;
}

/// Check if the current trace is sampled
pub fn isSampled(ctx: []const api.ContextKeyValue) bool {
    const span_ctx = getSpanContext(ctx) orelse return false;
    return span_ctx.isSampled();
}

/// Get trace flags from the context
pub fn getTraceFlags(ctx: []const api.ContextKeyValue) ?u8 {
    const span_ctx = getSpanContext(ctx) orelse return null;
    return span_ctx.trace_flags;
}

/// Get trace state from the context
pub fn getTraceState(ctx: []const api.ContextKeyValue) ?[]const u8 {
    const span_ctx = getSpanContext(ctx) orelse return null;
    return span_ctx.trace_state;
}

/// Create a context with updated sampling decision
pub fn withSamplingDecision(
    allocator: std.mem.Allocator,
    ctx: []const api.ContextKeyValue,
    should_sample: bool,
) ![]api.ContextKeyValue {
    return ownedWithKeyValue(allocator, ctx, context_keys.sampling_decision_key, should_sample);
}

/// Get the sampling decision from the context
pub fn getSamplingDecision(ctx: []const api.ContextKeyValue) ?bool {
    return extractContextValue(ctx, context_keys.sampling_decision_key);
}

/// Create a context with updated trace flags
pub fn withTraceFlags(
    allocator: std.mem.Allocator,
    ctx: []const api.ContextKeyValue,
    flags: u8,
) ![]api.ContextKeyValue {
    return ownedWithKeyValue(allocator, ctx, context_keys.trace_flags_key, flags);
}

/// Create a context with updated trace state
pub fn withTraceState(
    allocator: std.mem.Allocator,
    ctx: []const api.ContextKeyValue,
    state: []const u8,
) ![]api.ContextKeyValue {
    return ownedWithKeyValue(allocator, ctx, context_keys.trace_state_key, state);
}

/// Start a new child span context from the current context
/// This creates a child span context and sets it as active
pub fn startChildSpan(
    allocator: std.mem.Allocator,
    ctx: []const api.ContextKeyValue,
    random: std.Random,
) ![]api.ContextKeyValue {
    const parent = getSpanContext(ctx) orelse return ownedWithKeyValue(allocator, ctx, context_keys.active_span_context_key, createRootSpanContext(random));

    return try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{
            .key = context_keys.active_span_context_key.key_id,
            .value = .{ .span_context = createRootSpanContext(random) },
        })
        .add(.{
            .key = context_keys.active_span_context_key.key_id,
            .value = .{ .span_context = createChildSpanContext(parent, random) },
        })
        .finish(allocator);
}

/// End the current active span by removing it from the context
/// If there was a parent span, it becomes active again
pub fn endActiveSpan(allocator: std.mem.allocator, ctx: []const api.ContextKeyValue) ![]api.ContextKeyValue {
    // Copy all values except the active span context
    var builder = api.ContextBuilder.init(allocator);
    for (ctx) |kv| {
        if (context_keys.active_span_context_key.key != kv.key) {
            builder = builder.add(kv);
        }
    }
    return builder.finish(allocator);
}

inline fn extractContextValue(ctx: []const api.ContextKeyValue, key: anytype) ?key.ValueType {
    const maybe_pair = api.ContextKeyValue.scanSlice(ctx, key);
    if (maybe_pair) |pair| return key.unwrapValue(pair.value);
    return null;
}

inline fn ownedWithKeyValue(
    allocator: std.mem.Allocator,
    ctx: []const api.ContextKeyValue,
    key: anytype,
    value: key.ValueType,
) ![]api.ContextKeyValue {
    return try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = key.key_id, .value = key.wrapValue(value) })
        .finish(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "getActiveSpanContext and getRemoteSpanContext" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    // Empty context should return null
    try testing.expect(getActiveSpanContext(ctx) == null);
    try testing.expect(getRemoteSpanContext(ctx) == null);

    // Add active span context
    const active_span = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    const ctx_with_active = try ownedWithKeyValue(allocator, ctx, context_keys.active_span_context_key, active_span);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_active);

    const retrieved_active = getActiveSpanContext(ctx_with_active);
    try testing.expect(retrieved_active != null);
    try testing.expectEqualSlices(u8, &active_span.trace_id.bytes, &retrieved_active.?.trace_id.bytes);

    // Add remote span context
    const remote_span = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x03} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x04} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = true,
    };

    const ctx_with_remote = try ownedWithKeyValue(allocator, ctx_with_active, context_keys.remote_span_context_key, remote_span);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_remote);

    const retrieved_remote = getRemoteSpanContext(ctx_with_remote);
    try testing.expect(retrieved_remote != null);
    try testing.expectEqualSlices(u8, &remote_span.trace_id.bytes, &retrieved_remote.?.trace_id.bytes);
}

test "getSpanContext prefers active over remote" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const active_span = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    const remote_span = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x03} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x04} ** 8),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = true,
    };

    // Context with both active and remote
    var ctx_builder = api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = context_keys.active_span_context_key.key_id, .value = .{ .span_context = active_span } });
    // context returned with build does not deep copy the strings, but is fine for this test.
    const ctx_with_active = try ctx_builder.build();
    defer allocator.free(ctx_with_active);

    const ctx_with_both = try ctx_builder
        .add(.{ .key = context_keys.remote_span_context_key.key_id, .value = .{ .span_context = remote_span } })
        .finish(allocator);
    defer allocator.free(ctx_with_both);

    const span_ctx = getSpanContext(ctx_with_both);
    try testing.expect(span_ctx != null);
    // Should return active span, not remote
    try testing.expectEqualSlices(u8, &active_span.trace_id.bytes, &span_ctx.?.trace_id.bytes);

    // Context with only remote
    const ctx_remote_only = try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = context_keys.remote_span_context_key.key_id, .value = .{ .span_context = remote_span } })
        .finish(allocator);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_remote_only);

    const remote_only_span = getSpanContext(ctx_remote_only);
    try testing.expect(remote_only_span != null);
    try testing.expectEqualSlices(u8, &remote_span.trace_id.bytes, &remote_only_span.?.trace_id.bytes);
}

test "withActiveSpanContext and withRemoteSpanContext" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const span_context = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    // Test active span context
    const ctx_with_active = try withActiveSpanContext(allocator, ctx, span_context);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_active);

    const retrieved_active = getActiveSpanContext(ctx_with_active);
    try testing.expect(retrieved_active != null);
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &retrieved_active.?.trace_id.bytes);

    // Test remote span context
    const ctx_with_remote = try withRemoteSpanContext(allocator, ctx, span_context);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_remote);

    const retrieved_remote = getRemoteSpanContext(ctx_with_remote);
    try testing.expect(retrieved_remote != null);
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &retrieved_remote.?.trace_id.bytes);
}

test "createChildSpanContext" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const parent = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = "parent=state",
        .is_remote = false,
    };

    const child = createChildSpanContext(parent, random);

    // Child should have same trace ID as parent
    try testing.expectEqualSlices(u8, &parent.trace_id.bytes, &child.trace_id.bytes);

    // Child should have different span ID
    try testing.expect(!std.mem.eql(u8, &parent.span_id.bytes, &child.span_id.bytes));

    // Child should inherit trace flags and state
    try testing.expectEqual(parent.trace_flags, child.trace_flags);
    try testing.expectEqualStrings("parent=state", child.trace_state.?);
}

test "createRootSpanContext" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const root1 = createRootSpanContext(random);
    const root2 = createRootSpanContext(random);

    // Both should be valid
    try testing.expect(root1.isValid());
    try testing.expect(root2.isValid());

    // Should have different trace and span IDs
    try testing.expect(!std.mem.eql(u8, &root1.trace_id.bytes, &root2.trace_id.bytes));
    try testing.expect(!std.mem.eql(u8, &root1.span_id.bytes, &root2.span_id.bytes));
}

test "hasSpanContext functions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    // Empty context
    try testing.expect(!hasSpanContext(ctx));
    try testing.expect(!hasActiveSpanContext(ctx));
    try testing.expect(!hasRemoteSpanContext(ctx));

    const span_context = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = 1,
        .trace_state = null,
        .is_remote = false,
    };

    // Context with active span
    const ctx_with_active = try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = context_keys.active_span_context_key.key_id, .value = .{ .span_context = span_context } })
        .finish(allocator);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_active);

    try testing.expect(hasSpanContext(ctx_with_active));
    try testing.expect(hasActiveSpanContext(ctx_with_active));
    try testing.expect(!hasRemoteSpanContext(ctx_with_active));

    // Context with remote span
    const ctx_with_remote = try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = context_keys.remote_span_context_key.key_id, .value = .{ .span_context = span_context } })
        .finish(allocator);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_remote);

    try testing.expect(hasSpanContext(ctx_with_remote));
    try testing.expect(!hasActiveSpanContext(ctx_with_remote));
    try testing.expect(hasRemoteSpanContext(ctx_with_remote));
}

test "trace information getters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const span_context = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 }),
        .span_id = api.common.SpanId.fromBytes([_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 }),
        .trace_flags = 0x01,
        .trace_state = "test=state",
        .is_remote = false,
    };

    const ctx_with_span = try api.ContextBuilder.init(allocator)
        .addMany(ctx)
        .add(.{ .key = context_keys.active_span_context_key.key_id, .value = .{ .span_context = span_context } })
        .finish(allocator);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_span);

    // Test trace ID getter
    const trace_id = getTraceId(ctx_with_span);
    try testing.expect(trace_id != null);
    try testing.expectEqualSlices(u8, &span_context.trace_id.bytes, &trace_id.?.bytes);

    // Test span ID getter
    const span_id = getActiveSpanId(ctx_with_span);
    try testing.expect(span_id != null);
    try testing.expectEqualSlices(u8, &span_context.span_id.bytes, &span_id.?.bytes);

    // Test sampling check
    try testing.expect(isSampled(ctx_with_span));

    // Test trace flags getter
    const flags = getTraceFlags(ctx_with_span);
    try testing.expect(flags != null);
    try testing.expectEqual(@as(u8, 0x01), flags.?);

    // Test trace state getter
    const state = getTraceState(ctx_with_span);
    try testing.expect(state != null);
    try testing.expectEqualStrings("test=state", state.?);
}

test "sampling decision utilities" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    // Initially no sampling decision
    try testing.expect(getSamplingDecision(ctx) == null);

    // Set sampling decision
    const ctx_with_sampling = try withSamplingDecision(allocator, ctx, true);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_sampling);

    const decision = getSamplingDecision(ctx_with_sampling);
    try testing.expect(decision != null);
    try testing.expectEqual(true, decision.?);
}

test "startChildSpan creates proper child context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const ctx = try api.ContextKeyValue.initOwnedSlice(allocator, &.{});
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    // Start child span in empty context should create root span
    const ctx_with_root = try startChildSpan(allocator, ctx, random);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_root);

    const root_span = getActiveSpanContext(ctx_with_root);
    try testing.expect(root_span != null);
    try testing.expect(root_span.?.isValid());

    // Start child span with existing span should create child
    const ctx_with_child = try startChildSpan(allocator, ctx_with_root, random);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx_with_child);

    const child_span = getActiveSpanContext(ctx_with_child);
    try testing.expect(child_span != null);
    try testing.expect(child_span.?.isValid());

    // Child should have same trace ID as parent
    try testing.expectEqualSlices(u8, &root_span.?.trace_id.bytes, &child_span.?.trace_id.bytes);

    // Child should have different span ID
    try testing.expect(!std.mem.eql(u8, &root_span.?.span_id.bytes, &child_span.?.span_id.bytes));
}

test "getActiveSpan returns invalid noop when no context attached" {
    const testing = std.testing;
    // Ensure no implicit context is set (tests run serially, threadlocal starts at &.{})
    const prior = implicit.attach(&.{});
    defer implicit.detach(prior);

    const span = getActiveSpan();
    try testing.expect(!span.getSpanContext().isValid());
    try testing.expect(!span.isRecording());
}

test "getActiveSpan returns valid noop after attach" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const span_ctx = api.trace.Span.Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{0x01} ** 16),
        .span_id = api.common.SpanId.fromBytes([_]u8{0x02} ** 8),
        .trace_flags = api.trace.Span.Context.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };

    const ctx = try withActiveSpanContext(allocator, &.{}, span_ctx);
    defer api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    const token = implicit.attach(ctx);
    defer implicit.detach(token);

    const active = getActiveSpan();
    try testing.expect(active.getSpanContext().isValid());
    try testing.expect(!active.isRecording()); // noop span, not a recording bridge
    try testing.expectEqualSlices(u8, &span_ctx.trace_id.bytes, &active.getSpanContext().trace_id.bytes);
    try testing.expectEqualSlices(u8, &span_ctx.span_id.bytes, &active.getSpanContext().span_id.bytes);
}
