const std = @import("std");

const Timeout = @This();

start: i64,
timeout: ?u64,

fn milliTimestamp() i64 {
    var ts: std.posix.system.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub inline fn init(timeout_ms: ?u64) Timeout {
    return .{
        .start = milliTimestamp(),
        .timeout = timeout_ms,
    };
}

pub inline fn elapsed(self: *const Timeout) u64 {
    return @as(u64, @intCast(milliTimestamp() - self.start));
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
