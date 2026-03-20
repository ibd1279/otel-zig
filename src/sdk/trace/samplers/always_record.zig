//! AlwaysRecordSampler - Ensures every span reaches the SpanProcessor
//!
//! Wraps another sampler and converts DROP decisions to RECORD_ONLY, so
//! processors can see all spans without exporting them. Useful for accurate
//! span-to-metrics processing.
//!
//! Routing table:
//!   | inner decision      | AlwaysRecord decision |
//!   | ------------------- | --------------------- |
//!   | drop                | record_only           |
//!   | record_only         | record_only           |
//!   | record_and_sample   | record_and_sample     |

const std = @import("std");
const otel_api = @import("otel-api");
const Sampler = otel_api.trace.Sampler;

pub const AlwaysRecordSampler = struct {
    inner: Sampler,

    pub fn init(inner: Sampler) AlwaysRecordSampler {
        return .{ .inner = inner };
    }

    pub fn shouldSample(self: *const AlwaysRecordSampler, params: Sampler.Params) Sampler.Result {
        var result = self.inner.shouldSample(params);
        if (result.decision == .drop) result.decision = .record_only;
        return result;
    }

    pub fn getDescription(self: *const AlwaysRecordSampler) []const u8 {
        _ = self;
        return "AlwaysRecordSampler";
    }
};

const testing = std.testing;
const TraceId = otel_api.common.TraceId;

test "AlwaysRecord - drop becomes record_only" {
    const sampler = AlwaysRecordSampler.init(.{ .drop = {} });
    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test",
        .span_kind = .internal,
    });
    try testing.expectEqual(Sampler.Decision.record_only, result.decision);
}

test "AlwaysRecord - record_and_sample passes through" {
    const sampler = AlwaysRecordSampler.init(.{ .keep = {} });
    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test",
        .span_kind = .internal,
    });
    try testing.expectEqual(Sampler.Decision.record_and_sample, result.decision);
}

test "AlwaysRecord - record_only passes through" {
    // Construct a sampler that returns record_only by bridging a custom impl
    const RecordOnlySampler = struct {
        pub fn shouldSample(self: *const @This(), params: Sampler.Params) Sampler.Result {
            _ = self;
            _ = params;
            return .{ .decision = .record_only };
        }
        pub fn enabled(self: *const @This()) bool {
            _ = self;
            return true;
        }
        pub fn getDescription(self: *const @This()) []const u8 {
            _ = self;
            return "RecordOnly";
        }
    };
    var inner_impl = RecordOnlySampler{};
    const inner = Sampler{ .bridge = otel_api.trace.Sampler.Bridge.init(&inner_impl) };
    const sampler = AlwaysRecordSampler.init(inner);
    const result = sampler.shouldSample(.{
        .allocator = testing.allocator,
        .context = &.{},
        .trace_id = TraceId.fromBytes([_]u8{1} ** 16),
        .span_name = "test",
        .span_kind = .internal,
    });
    try testing.expectEqual(Sampler.Decision.record_only, result.decision);
}

test "AlwaysRecord - description" {
    const sampler = AlwaysRecordSampler.init(.{ .drop = {} });
    try testing.expectEqualStrings("AlwaysRecordSampler", sampler.getDescription());
}
