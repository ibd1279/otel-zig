const std = @import("std");

const Timeout = @This();

io: std.Io,
start: i64,
timeout: ?u64,

fn milliTimestamp(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

pub inline fn init(io: std.Io, timeout_ms: ?u64) Timeout {
    return .{
        .io = io,
        .start = milliTimestamp(io),
        .timeout = timeout_ms,
    };
}

pub inline fn elapsed(self: *const Timeout) u64 {
    return @as(u64, @intCast(milliTimestamp(self.io) - self.start));
}

pub inline fn isExpired(self: *const Timeout) bool {
    return if (self.timeout) |to| to <= self.elapsed() else false;
}

pub inline fn remaining(self: *const Timeout) !?u64 {
    return if (self.timeout) |to| blk: {
        const spent = self.elapsed();
        break :blk if (to <= spent) error.expired_timeout else to - spent;
    } else null;
}
