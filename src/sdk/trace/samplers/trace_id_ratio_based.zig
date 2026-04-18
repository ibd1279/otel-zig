//! TraceIdRatioBasedSampler - Samples spans based on trace ID hash ratio
//!
//! This sampler makes sampling decisions based on a configured ratio by
//! hashing the trace ID and comparing the result against the ratio threshold.

const std = @import("std");
const otel_api = @import("otel-api");

const SampleParams = otel_api.trace.Sampler.Params;
const SamplingResult = otel_api.trace.SamplingResult;
const SamplingDecision = otel_api.trace.SamplingDecision;
const TraceId = otel_api.common.TraceId;

/// Sampler that samples spans based on trace ID hash and a configured ratio
pub const TraceIdRatioBasedSampler = struct {
    const max_threshold = 0xFFFFFFFFFFFFFF;
    const max_th: [14]u8 = [_]u8{'F'} ** 14;
    threshold: u56,
    desc_buffer: [56]u8 = [_]u8{0} ** 56,
    desc_len: u8,
    th_buffer: [14]u8 = [_]u8{'0'} ** 14,
    th_len: u8 = 1,

    /// Create a new TraceIdRatioBasedSampler; precision is of the threshold, not the float.
    pub fn init(ratio: f64, precision: u6) TraceIdRatioBasedSampler {
        const desc_format = "TraceIdRatioBased{{{d}}}";
        const desc_format_fallback = "TraceIdRatioBased{DescriptionError}";
        var desc_buffer = [_]u8{0} ** 56;

        if (ratio >= 1.0) {
            const desc = std.fmt.bufPrint(&desc_buffer, desc_format, .{1.0}) catch blk: {
                @memcpy(desc_buffer[0..desc_format_fallback.len], desc_format_fallback);
                break :blk desc_format_fallback;
            };
            return .{
                .threshold = 0,
                .desc_buffer = desc_buffer,
                .desc_len = @intCast(desc.len),
            };
        }
        const clamped_ratio = std.math.clamp(ratio, 0.0, 1.0);
        const threshold_float = (1.0 - clamped_ratio) * @as(f64, @floatFromInt(1 << 56));
        const threshold_toobig: u64 = @trunc(threshold_float);
        if (threshold_toobig > max_threshold) {
            // What was passed in is either 0.0 or effectively 0.0, so treat as 0.0
            const desc = std.fmt.bufPrint(&desc_buffer, desc_format, .{0.0}) catch blk: {
                @memcpy(desc_buffer[0..desc_format_fallback.len], desc_format_fallback);
                break :blk desc_format_fallback;
            };

            return .{
                .threshold = max_threshold,
                .desc_buffer = desc_buffer,
                .desc_len = @intCast(desc.len),
                .th_buffer = max_th,
                .th_len = @intCast(max_th.len),
            };
        }

        const desc = std.fmt.bufPrint(&desc_buffer, desc_format, .{clamped_ratio}) catch blk: {
            @memcpy(desc_buffer[0..desc_format_fallback.len], desc_format_fallback);
            break :blk desc_format_fallback;
        };

        const mask: u56 = if (precision < 14) ~(@as(u56, max_threshold) >> (precision * 4)) else max_threshold;
        const threshold: u56 = @as(u56, @truncate(threshold_toobig)) & mask;

        const th_bigend = std.mem.nativeToBig(u56, threshold);
        var th_buffer = std.fmt.bytesToHex(std.mem.asBytes(&th_bigend), .lower);
        th_buffer[14] = '0';
        th_buffer[15] = '0';
        var th_len: u8 = precision;
        while (th_len > 0) : (th_len -= 1) {
            if (th_buffer[th_len] != '0') break;
        }
        if (th_len != 14) th_len += 1;

        return .{
            .threshold = threshold,
            .desc_buffer = desc_buffer,
            .desc_len = @intCast(desc.len),
            .th_buffer = th_buffer[0..14].*,
            .th_len = th_len,
        };
    }

    /// Make sampling decision based on trace ID hash
    pub fn shouldSample(self: *const TraceIdRatioBasedSampler, params: otel_api.trace.Sampler.Params) otel_api.trace.Sampler.Result {
        // Warn when used as a child sampler — only reliable as a root sampler inside ParentBased.
        if (otel_api.trace.trace_context.getSpanContext(params.context) != null) {
            // Check whether parent is using ProbabilitySampler (th or rv in ot= tracestate)
            const using_probability = blk: {
                if (params.parent_ctx) |pctx| if (pctx.trace_state) |ts| {
                    var buf: [otel_api.trace.StateKeyValue.max_pairs]otel_api.trace.StateKeyValue = undefined;
                    const state = otel_api.trace.StateKeyValue.fromString(ts, &buf);
                    if (otel_api.trace.StateKeyValue.scanSlice(state, "ot")) |ot| {
                        const ot_state = otel_api.trace.OtState.fromString(ot.value orelse "") catch otel_api.trace.OtState{};
                        if (ot_state.th != null or ot_state.rv != null) break :blk true;
                    }
                };
                break :blk false;
            };
            const msg = if (using_probability)
                "TraceIdRatioBased is operating as a child sampler and a parent is using ProbabilitySampler. Use ProbabilitySampler instead."
            else
                "TraceIdRatioBased is operating as a child sampler; behavior is subject to change. Use ParentBased(root: TraceIdRatioBased) instead.";
            otel_api.common.reportError(.{
                .component = .tracer,
                .operation = "shouldSample",
                .error_type = .configuration,
                .message = msg,
            });
        }

        const random = blk: {
            var random = std.mem.bytesToValue(u56, params.trace_id.bytes[otel_api.common.TraceId.length - 7 ..]);
            if (params.parent_ctx) |parent_ctx| if (parent_ctx.trace_state) |trace_state| {
                var buffer: [otel_api.trace.StateKeyValue.max_pairs]otel_api.trace.StateKeyValue = undefined;
                const state = otel_api.trace.StateKeyValue.fromString(trace_state, &buffer);
                if (otel_api.trace.StateKeyValue.scanSlice(state, "ot")) |ot| {
                    const ot_state = otel_api.trace.OtState.fromString(ot.value orelse "") catch otel_api.trace.OtState{};
                    if (ot_state.rv) |rv| random = rv;
                }
            };
            break :blk random;
        };

        // Sample if hash is below threshold
        if (random >= self.threshold) {
            return otel_api.trace.Sampler.Result{ .decision = .record_and_sample };
        } else {
            return otel_api.trace.Sampler.Result{ .decision = .drop };
        }
    }

    /// Get description of this sampler
    pub fn getDescription(self: *const TraceIdRatioBasedSampler) []const u8 {
        return self.desc_buffer[0..self.desc_len];
    }
};

// Tests
const testing = std.testing;

test "TraceIdRatioBasedSampler - threshold test" {
    {
        const sampler = TraceIdRatioBasedSampler.init(0.25, 14);
        const threshold = sampler.threshold;

        try testing.expectEqual(@as(u56, 0xc0000000000000), threshold);
        try testing.expectEqualStrings("c0000000000000", sampler.th_buffer[0..]);
        try testing.expectEqual(@as(u8, 1), sampler.th_len);
        try testing.expectEqualStrings("c", sampler.th_buffer[0..sampler.th_len]);
    }
    {
        const sampler = TraceIdRatioBasedSampler.init(0.0001, 6);
        const threshold = sampler.threshold;
        try testing.expectEqual(@as(u56, 0xfff97200000000), threshold);
        try testing.expectEqualStrings("fff97200000000", sampler.th_buffer[0..]);
        try testing.expectEqual(@as(u8, 6), sampler.th_len);
        try testing.expectEqualStrings("fff972", sampler.th_buffer[0..sampler.th_len]);
    }
    {
        const sampler = TraceIdRatioBasedSampler.init(0.33333333333, 8);
        const threshold = sampler.threshold;

        try testing.expectEqual(@as(u56, 0xaaaaaaaa000000), threshold);
        try testing.expectEqualStrings("aaaaaaaa000000", sampler.th_buffer[0..]);
        try testing.expectEqual(@as(u8, 8), sampler.th_len);
        try testing.expectEqualStrings("aaaaaaaa", sampler.th_buffer[0..sampler.th_len]);
    }
    {
        const sampler = TraceIdRatioBasedSampler.init(0.00000000001, 13);
        const threshold = sampler.threshold;

        try testing.expectEqual(@as(u56, 0xfffffffff50140), threshold);
        try testing.expectEqualStrings("fffffffff50140", sampler.th_buffer[0..]);
        try testing.expectEqual(@as(u8, 13), sampler.th_len);
        try testing.expectEqualStrings("fffffffff5014", sampler.th_buffer[0..sampler.th_len]);
    }
    {
        const sampler = TraceIdRatioBasedSampler.init(0.125, 1);
        const threshold = sampler.threshold;

        try testing.expectEqual(@as(u56, 0xe0000000000000), threshold);
        try testing.expectEqualStrings("e0000000000000", sampler.th_buffer[0..]);
        try testing.expectEqual(@as(u8, 1), sampler.th_len);
        try testing.expectEqualStrings("e", sampler.th_buffer[0..sampler.th_len]);
    }
}

test "TraceIdRatioBasedSampler - ratio 1.0 always samples" {
    const sampler = TraceIdRatioBasedSampler.init(1.0, 14);

    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    });
    try testing.expect(result.decision == .record_and_sample);
}

test "TraceIdRatioBasedSampler - ratio 0.0 never samples" {
    const sampler = TraceIdRatioBasedSampler.init(0.0, 14);

    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    });
    try testing.expect(result.decision == .drop);
}

test "TraceIdRatioBasedSampler - ratio clamping" {
    // Test ratio > 1.0 gets clamped
    const sampler1 = TraceIdRatioBasedSampler.init(1.5, 14);
    try testing.expect(sampler1.threshold == 0);

    // Test ratio < 0.0 gets clamped
    const sampler2 = TraceIdRatioBasedSampler.init(-0.5, 14);
    try testing.expect(sampler2.threshold == 0xFFFFFFFFFFFFFF);
}

test "TraceIdRatioBasedSampler - deterministic behavior" {
    const sampler = TraceIdRatioBasedSampler.init(0.5, 14);

    const params = SampleParams{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    };

    // Same trace ID should always produce same result
    const result1 = sampler.shouldSample(params);
    const result2 = sampler.shouldSample(params);
    const result3 = sampler.shouldSample(params);
    const result4 = sampler.shouldSample(params);
    try testing.expect(result1.decision == result2.decision);
    try testing.expect(result1.decision == result3.decision);
    try testing.expect(result1.decision == result4.decision);
}

test "TraceIdRatioBasedSampler - different trace IDs" {
    const sampler = TraceIdRatioBasedSampler.init(0.5, 14);
    const io = std.testing.io;
    var id_generator = try @import("../id_generator.zig").RandomIdGenerator.init(io);

    // Test with different trace IDs to ensure we get some variation
    var sampled_count: u32 = 0;
    var total_count: u32 = 0;

    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        // const trace_id = TraceId.fromBytes([_]u8{i} ** 16);
        const trace_id = TraceId.fromBytes(id_generator.generateTraceId());
        const params = SampleParams{
            .allocator = testing.allocator,
            .context = &.{},
            .trace_id = trace_id,
            .span_name = "test-span",
            .span_kind = .internal,
        };

        const result = sampler.shouldSample(params);
        if (result.decision == .record_and_sample) {
            sampled_count += 1;
        }
        total_count += 1;
    }

    // With 100 samples and 50% ratio, we should get some sampling
    // (not exactly 50 due to hash distribution, but should be > 0 and < 100)
    try testing.expect(sampled_count > 10);
    try testing.expect(sampled_count < total_count - 10);
}

test "TraceIdRatioBasedSampler - description" {
    const sampler = TraceIdRatioBasedSampler.init(0.5, 14);
    const description = sampler.getDescription();
    try testing.expectEqualStrings("TraceIdRatioBased{0.5}", description);
}

test "TraceIdRatioBasedSampler - warns when used as child sampler" {
    const allocator = testing.allocator;

    var mock = otel_api.common.MockErrorHandler.init(allocator);
    defer mock.deinit();
    otel_api.common.setMockErrorHandler(&mock);
    defer otel_api.common.clearMockErrorHandler();

    const sampler = TraceIdRatioBasedSampler.init(1.0, 14);

    const parent_ctx = otel_api.trace.Span.Context{
        .trace_id = otel_api.common.TraceId.fromBytes([_]u8{1} ** 16),
        .span_id = otel_api.common.SpanId.fromBytes([_]u8{2} ** 8),
        .trace_flags = otel_api.trace.Span.Context.SAMPLED_FLAG,
        .trace_state = null,
        .is_remote = false,
    };
    const ctx = try otel_api.trace.trace_context.withActiveSpanContext(allocator, &.{}, parent_ctx);
    defer otel_api.ContextKeyValue.deinitOwnedSlice(allocator, ctx);

    _ = sampler.shouldSample(.{
        .allocator = allocator,
        .context = ctx,
        .trace_id = otel_api.common.TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "child",
        .span_kind = .internal,
    });

    try testing.expectEqual(@as(usize, 1), mock.errorCount());
    try testing.expect(mock.hasErrorWithMessage(
        "TraceIdRatioBased is operating as a child sampler; behavior is subject to change. Use ParentBased(root: TraceIdRatioBased) instead.",
    ));
}
