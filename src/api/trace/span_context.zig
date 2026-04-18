//! OpenTelemetry Span Context
//!
//! Context represents the immutable portion of a span that must be propagated
//! to child spans and across process boundaries. It contains the trace identifier,
//! span identifier, trace flags, and trace state according to the W3C Trace Context
//! specification.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#spancontext
//! See: https://www.w3.org/TR/trace-context/

const std = @import("std");
const api = struct {
    const common = struct {
        const SpanId = @import("../common/types.zig").SpanId;
        const TraceId = @import("../common/types.zig").TraceId;
    };
};

const Context = @This();

/// Context represents the immutable span identifier and associated metadata
/// 128-bit trace identifier
trace_id: api.common.TraceId,

/// 64-bit span identifier
span_id: api.common.SpanId,

/// 8-bit trace flags containing sampling decision and other flags
trace_flags: u8,

/// Optional W3C trace state for vendor-specific propagation data
trace_state: ?[]const u8,

/// Whether this span context was extracted from a remote process
is_remote: bool,

/// Trace flags bit positions according to W3C specification
pub const SAMPLED_FLAG: u8 = 0x01;

/// Create an invalid span context (all zeros)
pub const invalid: Context = .{
    .trace_id = api.common.TraceId.fromBytes([_]u8{0} ** api.common.TraceId.length),
    .span_id = api.common.SpanId.fromBytes([_]u8{0} ** api.common.SpanId.length),
    .trace_flags = 0,
    .trace_state = null,
    .is_remote = false,
};

/// Generate a new span context with random trace and span IDs
pub fn generate(random: std.Random) Context {
    var trace_id_bytes: [api.common.TraceId.length]u8 = undefined;
    var span_id_bytes: [api.common.SpanId.length]u8 = undefined;

    // Generate non-zero trace_id
    while (true) {
        random.bytes(&trace_id_bytes);
        if (!std.mem.allEqual(u8, &trace_id_bytes, 0)) break;
    }

    // Generate non-zero span_id
    while (true) {
        random.bytes(&span_id_bytes);
        if (!std.mem.allEqual(u8, &span_id_bytes, 0)) break;
    }

    return Context{
        .trace_id = api.common.TraceId.fromBytes(trace_id_bytes),
        .span_id = api.common.SpanId.fromBytes(span_id_bytes),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
}

/// Create a new span context with the same trace ID but new span ID
pub fn fromTraceId(trace_id: api.common.TraceId, random: std.Random) Context {
    var span_id_bytes: [8]u8 = undefined;

    // Generate non-zero span_id
    while (true) {
        random.bytes(&span_id_bytes);
        if (!std.mem.allEqual(u8, &span_id_bytes, 0)) break;
    }

    return Context{
        .trace_id = trace_id,
        .span_id = api.common.SpanId.fromBytes(span_id_bytes),
        .trace_flags = 0,
        .trace_state = null,
        .is_remote = false,
    };
}

pub fn deinit(self: Context, allocator: std.mem.Allocator) void {
    if (self.trace_state) |ts| allocator.free(ts);
}

/// Check if this span context is valid (non-zero trace_id and span_id)
pub fn isValid(self: Context) bool {
    return self.trace_id.isValid() and self.span_id.isValid();
}

/// Check if this span is sampled according to trace flags
pub fn isSampled(self: Context) bool {
    return (self.trace_flags & SAMPLED_FLAG) != 0;
}

/// Create a copy of this span context with updated trace state (takes ownership of the tracestate)
pub fn withTraceState(self: Context, state: ?[]const u8) Context {
    return Context{
        .trace_id = self.trace_id,
        .span_id = self.span_id,
        .trace_flags = self.trace_flags,
        .trace_state = state,
        .is_remote = self.is_remote,
    };
}

/// Create a copy of this span context marked as remote
pub fn asRemote(self: Context) Context {
    return Context{
        .trace_id = self.trace_id,
        .span_id = self.span_id,
        .trace_flags = self.trace_flags,
        .trace_state = self.trace_state,
        .is_remote = true,
    };
}

/// Create a copy of this span context with updated trace flags
pub fn withTraceFlags(self: Context, flags: u8) Context {
    return Context{
        .trace_id = self.trace_id,
        .span_id = self.span_id,
        .trace_flags = flags,
        .trace_state = self.trace_state,
        .is_remote = self.is_remote,
    };
}

/// Format span context as hex strings for debugging
pub fn format(self: Context, writer: anytype) !void {
    try writer.print("Context{{trace_id={f}, span_id={f}, flags=0x{x:0>2}, sampled={any}, remote={any}", .{
        self.trace_id,
        self.span_id,
        self.trace_flags,
        self.isSampled(),
        self.is_remote,
    });

    if (self.trace_state) |state| {
        try writer.print(", state=\"{s}\"", .{state});
    }

    try writer.writeAll("}");
}

/// Get trace ID as hex string (32 characters)
pub fn traceIdHex(self: Context, buf: *[32]u8) []const u8 {
    self.trace_id.toHexString(buf);
    return buf[0..];
}

/// Get span ID as hex string (16 characters)
pub fn spanIdHex(self: Context, buf: *[16]u8) []const u8 {
    self.span_id.toHexString(buf);
    return buf[0..];
}

/// Parse trace ID from hex string
pub fn parseTraceId(hex: []const u8) !?api.common.TraceId {
    const trace_id = api.common.TraceId.fromHexString(hex) catch return null;
    if (trace_id.isInvalid()) return null;
    return trace_id;
}

/// Parse span ID from hex string
pub fn parseSpanId(hex: []const u8) !?api.common.SpanId {
    const span_id = api.common.SpanId.fromHexString(hex) catch return null;
    if (span_id.isInvalid()) return null;
    return span_id;
}

test "Context invalid" {
    const invalid_ctx = Context.invalid;
    try std.testing.expect(!invalid_ctx.isValid());
    try std.testing.expect(!invalid_ctx.isSampled());
    try std.testing.expect(!invalid_ctx.is_remote);
    try std.testing.expectEqual(@as(u8, 0), invalid_ctx.trace_flags);
    try std.testing.expectEqual(@as(?[]const u8, null), invalid_ctx.trace_state);
}

test "Context generate" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const ctx1 = Context.generate(random);
    const ctx2 = Context.generate(random);

    // Both should be valid
    try std.testing.expect(ctx1.isValid());
    try std.testing.expect(ctx2.isValid());

    // Should have different IDs
    try std.testing.expect(!std.mem.eql(u8, &ctx1.trace_id.bytes, &ctx2.trace_id.bytes));
    try std.testing.expect(!std.mem.eql(u8, &ctx1.span_id.bytes, &ctx2.span_id.bytes));

    // Should not be sampled by default
    try std.testing.expect(!ctx1.isSampled());
    try std.testing.expect(!ctx2.isSampled());

    // Should not be remote by default
    try std.testing.expect(!ctx1.is_remote);
    try std.testing.expect(!ctx2.is_remote);
}

test "Context fromTraceId" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 });

    const ctx1 = Context.fromTraceId(trace_id, random);
    const ctx2 = Context.fromTraceId(trace_id, random);

    // Both should be valid
    try std.testing.expect(ctx1.isValid());
    try std.testing.expect(ctx2.isValid());

    // Should have same trace ID
    try std.testing.expectEqualSlices(u8, &trace_id.bytes, &ctx1.trace_id.bytes);
    try std.testing.expectEqualSlices(u8, &trace_id.bytes, &ctx2.trace_id.bytes);

    // Should have different span IDs
    try std.testing.expect(!std.mem.eql(u8, &ctx1.span_id.bytes, &ctx2.span_id.bytes));
}

test "Context sampling flags" {
    var ctx = Context.invalid;
    try std.testing.expect(!ctx.isSampled());

    ctx = ctx.withTraceFlags(Context.SAMPLED_FLAG);
    try std.testing.expect(ctx.isSampled());
    try std.testing.expectEqual(Context.SAMPLED_FLAG, ctx.trace_flags);

    ctx = ctx.withTraceFlags(0);
    try std.testing.expect(!ctx.isSampled());
}

test "Context trace state" {
    var ctx = Context.invalid;
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.trace_state);

    const state = "vendor1=value1,vendor2=value2";
    ctx = ctx.withTraceState(state);
    try std.testing.expectEqualStrings(state, ctx.trace_state.?);

    ctx = ctx.withTraceState(null);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.trace_state);
}

test "Context remote flag" {
    var ctx = Context.invalid;
    try std.testing.expect(!ctx.is_remote);

    ctx = ctx.asRemote();
    try std.testing.expect(ctx.is_remote);
}

test "Context hex formatting" {
    const ctx = Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .span_id = api.common.SpanId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .trace_flags = Context.SAMPLED_FLAG,
        .trace_state = "vendor=value",
        .is_remote = true,
    };

    var trace_buf: [32]u8 = undefined;
    var span_buf: [16]u8 = undefined;

    const trace_hex = ctx.traceIdHex(&trace_buf);
    const span_hex = ctx.spanIdHex(&span_buf);

    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", trace_hex);
    try std.testing.expectEqualStrings("0123456789abcdef", span_hex);
}

test "Context parse IDs" {
    // Valid trace ID
    const trace_id = try Context.parseTraceId("0123456789abcdef0123456789abcdef");
    try std.testing.expect(trace_id != null);
    try std.testing.expectEqual(@as(u8, 0x01), trace_id.?.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xef), trace_id.?.bytes[15]);

    // Invalid trace ID (all zeros)
    const zero_trace = try Context.parseTraceId("00000000000000000000000000000000");
    try std.testing.expect(zero_trace == null);

    // Invalid trace ID (wrong length)
    const short_trace = try Context.parseTraceId("0123456789abcdef");
    try std.testing.expect(short_trace == null);

    // Valid span ID
    const span_id = try Context.parseSpanId("0123456789abcdef");
    try std.testing.expect(span_id != null);
    try std.testing.expectEqual(@as(u8, 0x01), span_id.?.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xef), span_id.?.bytes[7]);

    // Invalid span ID (all zeros)
    const zero_span = try Context.parseSpanId("0000000000000000");
    try std.testing.expect(zero_span == null);

    // Invalid span ID (wrong length)
    const short_span = try Context.parseSpanId("01234567");
    try std.testing.expect(short_span == null);
}

test "Context format" {
    const ctx = Context{
        .trace_id = api.common.TraceId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .span_id = api.common.SpanId.fromBytes([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }),
        .trace_flags = Context.SAMPLED_FLAG,
        .trace_state = "vendor=value",
        .is_remote = true,
    };

    var buf: [512]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{ctx});

    try std.testing.expect(std.mem.find(u8, formatted, "0123456789abcdef0123456789abcdef") != null);
    try std.testing.expect(std.mem.find(u8, formatted, "0123456789abcdef") != null);
    try std.testing.expect(std.mem.find(u8, formatted, "sampled=true") != null);
    try std.testing.expect(std.mem.find(u8, formatted, "remote=true") != null);
    try std.testing.expect(std.mem.find(u8, formatted, "vendor=value") != null);
}
