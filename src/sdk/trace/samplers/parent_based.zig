//! ParentBasedSampler - Routes sampling decisions based on parent span context
//!
//! Implements the OTel spec ParentBased sampler with four delegate samplers:
//!
//!   | Parent  | is_remote | isSampled | Delegate                  |
//!   | ------- | --------- | --------- | ------------------------- |
//!   | absent  | n/a       | n/a       | root                      |
//!   | present | true      | true      | remote_parent_sampled     |
//!   | present | true      | false     | remote_parent_not_sampled |
//!   | present | false     | true      | local_parent_sampled      |
//!   | present | false     | false     | local_parent_not_sampled  |

const std = @import("std");
const otel_api = @import("otel-api");
const SampleParams = otel_api.trace.Sampler.Params;
const SamplingResult = otel_api.trace.Sampler.Result;
const Sampler = otel_api.trace.Sampler;
const TraceId = otel_api.common.TraceId;
const SpanId = otel_api.common.SpanId;
const trace_context = otel_api.trace.trace_context;

/// Sampler that routes to one of five delegates based on parent context.
pub const ParentBasedSampler = struct {
    root_sampler: Sampler,
    remote_parent_sampled: Sampler,
    remote_parent_not_sampled: Sampler,
    local_parent_sampled: Sampler,
    local_parent_not_sampled: Sampler,

    /// Optional delegate overrides. All default to AlwaysOn/AlwaysOff per spec.
    pub const Options = struct {
        remote_parent_sampled: Sampler = .{ .keep = {} },
        remote_parent_not_sampled: Sampler = .{ .drop = {} },
        local_parent_sampled: Sampler = .{ .keep = {} },
        local_parent_not_sampled: Sampler = .{ .drop = {} },
    };

    pub fn init(root: Sampler, options: Options) ParentBasedSampler {
        return .{
            .root_sampler = root,
            .remote_parent_sampled = options.remote_parent_sampled,
            .remote_parent_not_sampled = options.remote_parent_not_sampled,
            .local_parent_sampled = options.local_parent_sampled,
            .local_parent_not_sampled = options.local_parent_not_sampled,
        };
    }

    pub fn shouldSample(self: *const ParentBasedSampler, params: SampleParams) SamplingResult {
        const parent = trace_context.getSpanContext(params.context) orelse
            return self.root_sampler.shouldSample(params);

        const delegate = if (parent.is_remote)
            if (parent.isSampled()) self.remote_parent_sampled else self.remote_parent_not_sampled
        else
            if (parent.isSampled()) self.local_parent_sampled else self.local_parent_not_sampled;

        return delegate.shouldSample(params);
    }

    pub fn getDescription(self: *const ParentBasedSampler) []const u8 {
        _ = self;
        return "ParentBasedSampler";
    }
};

// Tests
const testing = std.testing;

fn makeCtxWithParent(allocator: std.mem.Allocator, sampled: bool, is_remote: bool) ![]otel_api.ContextKeyValue {
    const parent_span_context = otel_api.trace.Span.Context{
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = if (sampled) otel_api.trace.Span.Context.SAMPLED_FLAG else 0,
        .trace_state = null,
        .is_remote = is_remote,
    };
    return trace_context.withActiveSpanContext(allocator, &.{}, parent_span_context);
}

test "ParentBasedSampler - no parent delegates to root sampler" {
    const sampler = ParentBasedSampler.init(.{ .keep = {} }, .{});

    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "root-span",
        .span_kind = .server,
    });
    try testing.expectEqual(Sampler.Decision.record_and_sample, result.decision);
}

test "ParentBasedSampler - remote+sampled routes to remoteParentSampled" {
    var called = false;
    _ = &called;
    // Use always_off as root so we can confirm the delegate (always_on) wins
    const sampler = ParentBasedSampler.init(.{ .drop = {} }, .{
        .remote_parent_sampled = .{ .keep = {} },
    });

    const ctx = try makeCtxWithParent(testing.allocator, true, true);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, ctx);

    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = ctx,
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "child",
        .span_kind = .client,
    });
    try testing.expectEqual(Sampler.Decision.record_and_sample, result.decision);
}

test "ParentBasedSampler - remote+unsampled routes to remoteParentNotSampled" {
    const sampler = ParentBasedSampler.init(.{ .keep = {} }, .{
        .remote_parent_not_sampled = .{ .drop = {} },
    });

    const ctx = try makeCtxWithParent(testing.allocator, false, true);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, ctx);

    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = ctx,
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "child",
        .span_kind = .client,
    });
    try testing.expectEqual(Sampler.Decision.drop, result.decision);
}

test "ParentBasedSampler - local+sampled routes to localParentSampled" {
    const sampler = ParentBasedSampler.init(.{ .drop = {} }, .{
        .local_parent_sampled = .{ .keep = {} },
    });

    const ctx = try makeCtxWithParent(testing.allocator, true, false);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, ctx);

    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = ctx,
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "child",
        .span_kind = .internal,
    });
    try testing.expectEqual(Sampler.Decision.record_and_sample, result.decision);
}

test "ParentBasedSampler - local+unsampled routes to localParentNotSampled" {
    const sampler = ParentBasedSampler.init(.{ .keep = {} }, .{
        .local_parent_not_sampled = .{ .drop = {} },
    });

    const ctx = try makeCtxWithParent(testing.allocator, false, false);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(testing.allocator, ctx);

    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = ctx,
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "child",
        .span_kind = .internal,
    });
    try testing.expectEqual(Sampler.Decision.drop, result.decision);
}

test "ParentBasedSampler - description" {
    const sampler = ParentBasedSampler.init(.{ .drop = {} }, .{});
    try testing.expectEqualStrings("ParentBasedSampler", sampler.getDescription());
}
