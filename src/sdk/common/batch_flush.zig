//! Shared forceFlush state machine for batch span and log record processors.
//!
//! ## Required field shape for T:
//!   io: std.Io
//!   mutex: std.Io.Mutex
//!   flush_in_progress: std.atomic.Value(bool)
//!   flush_complete: std.Io.Condition
//!   export_in_progress: std.atomic.Value(bool)
//!   export_complete: std.Io.Condition
//!   is_shutdown: std.atomic.Value(bool)
//!
//! The `exportAndFlush` hook is called with `self.mutex` held and may release
//! and reacquire the mutex internally for export and exporter.forceFlush calls.

const std = @import("std");
const api = @import("otel-api");

fn milliTimestamp() i64 {
    var ts: std.posix.system.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn remainingMs(timeout_ms: ?u64, start_time: i64) ?u64 {
    return if (timeout_ms) |ms|
        ms -| @as(u64, @intCast(milliTimestamp() - start_time))
    else
        null;
}

/// Compile-time check that T has the required fields for performForceFlush.
pub fn validateProcessorShape(comptime T: type) void {
    comptime {
        if (!@hasField(T, "io")) @compileError(@typeName(T) ++ " missing field: io");
        if (!@hasField(T, "mutex")) @compileError(@typeName(T) ++ " missing field: mutex");
        if (!@hasField(T, "flush_in_progress")) @compileError(@typeName(T) ++ " missing field: flush_in_progress");
        if (!@hasField(T, "flush_complete")) @compileError(@typeName(T) ++ " missing field: flush_complete");
        if (!@hasField(T, "export_in_progress")) @compileError(@typeName(T) ++ " missing field: export_in_progress");
        if (!@hasField(T, "export_complete")) @compileError(@typeName(T) ++ " missing field: export_complete");
        if (!@hasField(T, "is_shutdown")) @compileError(@typeName(T) ++ " missing field: is_shutdown");
    }
}

/// Shared forceFlush state machine. Caller must not hold self.mutex.
/// exportAndFlush is invoked with self.mutex held; it may release and reacquire it.
pub fn performForceFlush(
    comptime T: type,
    self: *T,
    timeout_ms: ?u64,
    comptime exportAndFlush: fn (*T, ?u64) api.common.FlushResult,
) api.common.FlushResult {
    comptime validateProcessorShape(T);

    if (self.is_shutdown.load(.acquire)) return .failure;

    const start_time = milliTimestamp();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const was_flushing = self.flush_in_progress.swap(true, .seq_cst);
    if (was_flushing) {
        while (self.flush_in_progress.load(.acquire)) {
            if (remainingMs(timeout_ms, start_time) == 0) return .timeout;
            self.flush_complete.waitUncancelable(self.io, &self.mutex);
        }
        return .success;
    }
    defer {
        self.flush_in_progress.store(false, .release);
        self.flush_complete.broadcast(self.io);
    }

    while (self.export_in_progress.load(.acquire)) {
        if (remainingMs(timeout_ms, start_time) == 0) return .timeout;
        self.export_complete.waitUncancelable(self.io, &self.mutex);
    }
    self.export_in_progress.store(true, .release);
    defer {
        self.export_in_progress.store(false, .release);
        self.export_complete.broadcast(self.io);
    }

    return exportAndFlush(self, remainingMs(timeout_ms, start_time));
}
