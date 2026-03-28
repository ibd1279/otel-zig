//! OpenTelemetry SDK ID Generator
//!
//! This module provides ID generation utilities for traces and spans.
//! IDs are generated according to the OpenTelemetry specification:
//! - Trace IDs are 16 bytes (128 bits)
//! - Span IDs are 8 bytes (64 bits)
//! - IDs should be randomly generated with good entropy

const std = @import("std");
const builtin = @import("builtin");

/// ID generator interface for generating trace and span IDs
pub const IdGenerator = union(enum) {
    random: RandomIdGenerator,
    custom: CustomIdGenerator,

    /// Generate a new trace ID (16 bytes)
    pub fn generateTraceId(self: *IdGenerator) [16]u8 {
        return switch (self.*) {
            .random => |*gen| gen.generateTraceId(),
            .custom => |*gen| gen.generateTraceId(),
        };
    }

    /// Generate a new span ID (8 bytes)
    pub fn generateSpanId(self: *IdGenerator) [8]u8 {
        return switch (self.*) {
            .random => |*gen| gen.generateSpanId(),
            .custom => |*gen| gen.generateSpanId(),
        };
    }
};

/// Random ID generator using cryptographic random number generation
pub const RandomIdGenerator = struct {
    prng: std.Random.ChaCha,

    pub fn init() RandomIdGenerator {
        var seed: [32]u8 = undefined;
        fillRandomBytes(&seed);
        return .{
            .prng = std.Random.ChaCha.init(seed),
        };
    }

    fn fillRandomBytes(buf: []u8) void {
        const os = @import("builtin").os.tag;
        switch (os) {
            .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
                std.c.arc4random_buf(buf.ptr, buf.len);
            },
            .linux => {
                const rc = std.posix.system.getrandom(buf.ptr, buf.len, 0);
                if (rc < 0) {
                    // Fallback: use a time-based seed (not cryptographically secure)
                    var ts: std.posix.system.timespec = undefined;
                    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
                    const t: u64 = @bitCast(ts.sec *% 1_000_000_000 +% ts.nsec);
                    for (buf, 0..) |*b, i| b.* = @truncate(t >> @intCast((i % 8) * 8));
                }
            },
            else => {
                // Fallback: time-based seed
                var ts: std.posix.system.timespec = undefined;
                _ = std.posix.system.clock_gettime(.REALTIME, &ts);
                const t: u64 = @bitCast(ts.sec *% 1_000_000_000 +% ts.nsec);
                for (buf, 0..) |*b, i| b.* = @truncate(t >> @intCast((i % 8) * 8));
            },
        }
    }

    pub fn generateTraceId(self: *RandomIdGenerator) [16]u8 {
        var id: [16]u8 = undefined;
        self.prng.random().bytes(&id);

        // Ensure the ID is not all zeros (invalid)
        if (isZeroId(u128, &id)) {
            id[0] = 1;
        }

        return id;
    }

    pub fn generateSpanId(self: *RandomIdGenerator) [8]u8 {
        var id: [8]u8 = undefined;
        self.prng.random().bytes(&id);

        // Ensure the ID is not all zeros (invalid)
        if (isZeroId(u64, &id)) {
            id[0] = 1;
        }

        return id;
    }

    fn isZeroId(comptime T: type, id: *const [@sizeOf(T)]u8) bool {
        return std.mem.allEqual(u8, id, 0);
    }
};

/// Custom ID generator with user-provided generation functions
pub const CustomIdGenerator = struct {
    impl: *anyopaque,
    generateTraceIdFn: *const fn (impl: *anyopaque) [16]u8,
    generateSpanIdFn: *const fn (impl: *anyopaque) [8]u8,

    pub fn init(
        impl: *anyopaque,
        generateTraceIdFn: *const fn (impl: *anyopaque) [16]u8,
        generateSpanIdFn: *const fn (impl: *anyopaque) [8]u8,
    ) CustomIdGenerator {
        return .{
            .impl = impl,
            .generateTraceIdFn = generateTraceIdFn,
            .generateSpanIdFn = generateSpanIdFn,
        };
    }

    pub fn generateTraceId(self: *CustomIdGenerator) [16]u8 {
        return self.generateTraceIdFn(self.impl);
    }

    pub fn generateSpanId(self: *CustomIdGenerator) [8]u8 {
        return self.generateSpanIdFn(self.impl);
    }
};

/// Create a default random ID generator
pub fn createDefaultIdGenerator() IdGenerator {
    return .{ .random = RandomIdGenerator.init() };
}

/// Generate a trace ID using the default generator
pub fn generateTraceId() [16]u8 {
    var generator = createDefaultIdGenerator();
    return generator.generateTraceId();
}

/// Generate a span ID using the default generator
pub fn generateSpanId() [8]u8 {
    var generator = createDefaultIdGenerator();
    return generator.generateSpanId();
}

/// Format a trace ID as a hex string (requires a buffer of at least 32 bytes)
pub fn formatTraceId(id: [16]u8, buf: []u8) ![]const u8 {
    if (buf.len < 32) return error.BufferTooSmall;
    return std.fmt.bufPrint(buf, "{s:0>32}", .{std.fmt.bytesToHex(&id, .lower)}) catch unreachable;
}

/// Format a span ID as a hex string (requires a buffer of at least 16 bytes)
pub fn formatSpanId(id: [8]u8, buf: []u8) ![]const u8 {
    if (buf.len < 16) return error.BufferTooSmall;
    return std.fmt.bufPrint(buf, "{s:0>16}", .{std.fmt.bytesToHex(&id, .lower)}) catch unreachable;
}

/// Parse a trace ID from a hex string
pub fn parseTraceId(hex: []const u8) ![16]u8 {
    if (hex.len != 32) return error.InvalidLength;

    var id: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&id, hex);
    return id;
}

/// Parse a span ID from a hex string
pub fn parseSpanId(hex: []const u8) ![8]u8 {
    if (hex.len != 16) return error.InvalidLength;

    var id: [8]u8 = undefined;
    _ = try std.fmt.hexToBytes(&id, hex);
    return id;
}

test "RandomIdGenerator generates valid IDs" {
    const testing = std.testing;

    var generator = RandomIdGenerator.init();

    // Generate trace IDs
    const trace_id1 = generator.generateTraceId();
    const trace_id2 = generator.generateTraceId();

    // Should be 16 bytes
    try testing.expectEqual(@as(usize, 16), trace_id1.len);
    try testing.expectEqual(@as(usize, 16), trace_id2.len);

    // Should not be equal (extremely unlikely with random generation)
    try testing.expect(!std.mem.eql(u8, &trace_id1, &trace_id2));

    // Should not be all zeros
    var all_zeros = true;
    for (trace_id1) |byte| {
        if (byte != 0) {
            all_zeros = false;
            break;
        }
    }
    try testing.expect(!all_zeros);

    // Generate span IDs
    const span_id1 = generator.generateSpanId();
    const span_id2 = generator.generateSpanId();

    // Should be 8 bytes
    try testing.expectEqual(@as(usize, 8), span_id1.len);
    try testing.expectEqual(@as(usize, 8), span_id2.len);

    // Should not be equal
    try testing.expect(!std.mem.eql(u8, &span_id1, &span_id2));
}

test "CustomIdGenerator" {
    const testing = std.testing;

    const TestImpl = struct {
        trace_counter: u128 = 1,
        span_counter: u64 = 1,

        fn generateTrace(impl: *anyopaque) [16]u8 {
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            var id: [16]u8 = undefined;
            std.mem.writeInt(u128, &id, self.trace_counter, .big);
            self.trace_counter += 1;
            return id;
        }

        fn generateSpan(impl: *anyopaque) [8]u8 {
            const self = @as(*@This(), @ptrCast(@alignCast(impl)));
            var id: [8]u8 = undefined;
            std.mem.writeInt(u64, &id, self.span_counter, .big);
            self.span_counter += 1;
            return id;
        }
    };

    var impl = TestImpl{};
    const custom = CustomIdGenerator.init(&impl, TestImpl.generateTrace, TestImpl.generateSpan);
    var generator = IdGenerator{ .custom = custom };

    const trace_id1 = generator.generateTraceId();
    const trace_id2 = generator.generateTraceId();

    // Should be sequential
    try testing.expectEqual(@as(u128, 1), std.mem.readInt(u128, &trace_id1, .big));
    try testing.expectEqual(@as(u128, 2), std.mem.readInt(u128, &trace_id2, .big));

    const span_id1 = generator.generateSpanId();
    const span_id2 = generator.generateSpanId();

    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, &span_id1, .big));
    try testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, &span_id2, .big));
}

test "ID formatting and parsing" {
    const testing = std.testing;

    // Test trace ID
    const trace_id = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
    var trace_buf: [32]u8 = undefined;
    const trace_hex = try formatTraceId(trace_id, &trace_buf);
    try testing.expectEqualStrings("0123456789abcdeffedcba9876543210", trace_hex);

    const parsed_trace = try parseTraceId(trace_hex);
    try testing.expectEqualSlices(u8, &trace_id, &parsed_trace);

    // Test span ID
    const span_id = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    var span_buf: [16]u8 = undefined;
    const span_hex = try formatSpanId(span_id, &span_buf);
    try testing.expectEqualStrings("0123456789abcdef", span_hex);

    const parsed_span = try parseSpanId(span_hex);
    try testing.expectEqualSlices(u8, &span_id, &parsed_span);
}

test "convenience functions" {
    const testing = std.testing;

    const trace_id1 = generateTraceId();
    const trace_id2 = generateTraceId();

    try testing.expectEqual(@as(usize, 16), trace_id1.len);
    try testing.expect(!std.mem.eql(u8, &trace_id1, &trace_id2));

    const span_id1 = generateSpanId();
    const span_id2 = generateSpanId();

    try testing.expectEqual(@as(usize, 8), span_id1.len);
    try testing.expect(!std.mem.eql(u8, &span_id1, &span_id2));
}
