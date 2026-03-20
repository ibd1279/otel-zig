//! OpenTelemetry SDK Samplers
//!
//! This module provides concrete sampler implementations for the OpenTelemetry SDK.
//! Samplers make decisions about whether spans should be sampled, recorded, or dropped.

const std = @import("std");
const otel_api = @import("otel-api");
const TraceId = otel_api.common.TraceId;

const Sampler = otel_api.trace.Sampler;
const SamplerBridge = otel_api.trace.Sampler.Bridge;

// Import concrete sampler implementations
pub const TraceIdRatioBasedSampler = @import("trace_id_ratio_based.zig").TraceIdRatioBasedSampler;
pub const ParentBasedSampler = @import("parent_based.zig").ParentBasedSampler;
pub const AlwaysRecordSampler = @import("always_record.zig").AlwaysRecordSampler;

// Re-export create functions
pub const createTraceIdRatioBased = TraceIdRatioBasedSampler.init;
pub const createParentBased = ParentBasedSampler.init;
pub const createAlwaysRecord = AlwaysRecordSampler.init;

/// Create a TraceIdRatioBasedSampler wrapped in the Sampler interface
pub fn traceIdRatioBased(ratio: f64) Sampler {
    const sampler = std.heap.page_allocator.create(TraceIdRatioBasedSampler) catch unreachable;
    sampler.* = createTraceIdRatioBased(ratio, 14);
    return Sampler{ .bridge = SamplerBridge.init(sampler) };
}

/// Create a ParentBasedSampler wrapped in the Sampler interface.
/// Uses spec-default delegates (AlwaysOn/AlwaysOff). For custom delegates,
/// use `createParentBased(root, options)` directly.
pub fn parentBased(root_sampler: Sampler) Sampler {
    const sampler = std.heap.page_allocator.create(ParentBasedSampler) catch unreachable;
    sampler.* = createParentBased(root_sampler, .{});
    return Sampler{ .bridge = SamplerBridge.init(sampler) };
}

/// Create an AlwaysRecordSampler wrapped in the Sampler interface.
pub fn alwaysRecord(inner: Sampler) Sampler {
    const sampler = std.heap.page_allocator.create(AlwaysRecordSampler) catch unreachable;
    sampler.* = createAlwaysRecord(inner);
    return Sampler{ .bridge = SamplerBridge.init(sampler) };
}

pub const always_on: Sampler = .{ .keep = {} };
pub const always_off: Sampler = .{ .drop = {} };

// Tests
const testing = std.testing;

test "always_on sampler creation" {
    const sampler = always_on;

    const params = otel_api.trace.Sampler.Params{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
}

test "traceIdRatioBased sampler creation" {
    const sampler = traceIdRatioBased(1.0);

    const params = otel_api.trace.Sampler.Params{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
}

test "always_off creation" {
    const sampler = always_off;

    const params = otel_api.trace.Sampler.Params{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .drop);
}

test "parentBased sampler creation" {
    const root_sampler = always_on;
    const sampler = parentBased(root_sampler);

    const params = otel_api.trace.Sampler.Params{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_and_sample);
}

test "alwaysRecord sampler creation" {
    const sampler = alwaysRecord(always_off);

    const params = otel_api.trace.Sampler.Params{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test-span",
        .span_kind = .internal,
    };

    const result = sampler.shouldSample(params);
    try testing.expect(result.decision == .record_only);
}
