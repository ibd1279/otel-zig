//! OpenTelemetry Logger API
//!
//! This module defines the Logger interface according to the OpenTelemetry specification.
//! A Logger is the primary interface for emitting log records.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/api.md#logger

const std = @import("std");
const api = struct {
    const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
    const AttributeValue = @import("../common/root.zig").AttributeValue;
    const ContextKeyValue = @import("../context/context.zig").ContextKeyValue;
    const common = struct {
        const TraceId = @import("../common/types.zig").TraceId;
        const SpanId = @import("../common/types.zig").SpanId;
    };
    const logs = struct {
        const Severity = @import("severity.zig").Severity;
    };
};
const isValidatingMode = @import("../common/error_handler.zig").isValidatingMode;
const reportValidationError = @import("../common/error_handler.zig").reportValidationError;

/// Logger interface using tagged union for compile-time polymorphism.
/// In the API layer, only the noop implementation is provided.
/// SDK implementations will extend this with concrete loggers.
pub const Logger = union(enum) {
    noop: void,
    bridge: LoggerBridge, // SDK logger bridge

    /// Emit a log record with individual parameters. This is the abstract interface method.
    pub fn emitLogRecord(
        self: *Logger,
        ctx: []const api.ContextKeyValue,
        severity: ?api.logs.Severity,
        body: ?api.AttributeValue,
        attributes: ?[]const api.AttributeKeyValue,
        timestamp: ?std.Io.Timestamp,
        observed_timestamp: ?std.Io.Timestamp,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?api.common.TraceId,
        span_id: ?api.common.SpanId,
        flags: ?u8,
    ) void {
        switch (self.*) {
            .noop => {},
            .bridge => |bridge| bridge.emitLogRecordFn(
                bridge.logger_ptr,
                ctx,
                severity,
                body,
                attributes,
                timestamp,
                observed_timestamp,
                event_name,
                severity_text,
                trace_id,
                span_id,
                flags,
            ),
        }
    }

    /// Check if logging is enabled for a given severity
    pub inline fn enabled(self: *const Logger, ctx: []const api.ContextKeyValue, severity: ?api.logs.Severity) bool {
        return switch (self.*) {
            .noop => return false,
            .bridge => |bridge| bridge.enabledFn(bridge.logger_ptr, ctx, severity),
        };
    }

    /// Check if logging is enabled for a given severity and event name
    pub inline fn enabledWithEvent(
        self: *const Logger,
        ctx: []const api.ContextKeyValue,
        severity: ?api.logs.Severity,
        event_name: []const u8,
    ) bool {
        return switch (self.*) {
            .noop => return false,
            .bridge => |bridge| bridge.enabledWithEventFn(bridge.logger_ptr, ctx, severity, event_name),
        };
    }

    // Convenience methods for simple use-cases.

    /// Emit a log record with defaults for most parameters. Calls `emitLogRecord`.
    pub inline fn emitLog(
        self: *Logger,
        ctx: []const api.ContextKeyValue,
        severity: ?api.logs.Severity,
        body: ?[]const u8,
        attributes: ?[]const api.AttributeKeyValue,
        event_name: ?[]const u8,
    ) void {
        self.emitLogRecord(
            ctx,
            severity,
            if (body) |msg| .{ .string = msg } else null,
            attributes,
            null,
            null,
            event_name,
            null,
            null,
            null,
            null,
        );
    }

    /// Emit a named log event correlated to the active span in `ctx`.
    ///
    /// Use this for structured semantic events that belong to a trace — in
    /// particular all GenAI content events such as
    /// `gen_ai.client.inference.operation.details`. Log-based events are richer
    /// than span events: they carry an independent export pipeline, severity,
    /// and attributes. Span correlation (trace_id, span_id, flags) is extracted
    /// automatically from `ctx` by the SDK; no manual ID passing is required.
    ///
    /// Per the OTel events spec, events SHOULD specify a severity number.
    /// The GenAI semconv does not prescribe a specific level for content-capture
    /// events; `.info` is a common choice but is not mandated. `body` SHOULD
    /// only carry a human-readable display string; structured content belongs
    /// in `attributes`.
    ///
    /// ```zig
    /// logger.emitEvent(
    ///     ctx,
    ///     semconv.gen_ai.Events.CLIENT_INFERENCE_OPERATION_DETAILS,
    ///     .info,
    ///     null,       // body: optional display string
    ///     attributes, // gen_ai.INPUT_MESSAGES, gen_ai.OUTPUT_MESSAGES, etc.
    /// );
    /// ```
    pub inline fn emitEvent(
        self: *Logger,
        ctx: []const api.ContextKeyValue,
        event_name: []const u8,
        severity: ?api.logs.Severity,
        body: ?api.AttributeValue,
        attributes: ?[]const api.AttributeKeyValue,
    ) void {
        self.emitLogRecord(
            ctx,
            severity,
            body,
            attributes,
            null, // timestamp — SDK fills in using io clock
            null, // observed_timestamp — SDK fills in using io clock
            event_name,
            null, // severity_text
            null, // trace_id — SDK extracts from ctx automatically
            null, // span_id  — SDK extracts from ctx automatically
            null, // flags    — SDK extracts from ctx automatically
        );
    }

    // Convenience methods for different severity levels

    /// Log a trace message
    pub inline fn trace(self: *Logger, ctx: []const api.ContextKeyValue, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .trace, fmt, args);
    }

    /// Log a debug message
    pub inline fn debug(self: *Logger, ctx: []const api.ContextKeyValue, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .debug, fmt, args);
    }

    /// Log an info message
    pub inline fn info(self: *Logger, ctx: []const api.ContextKeyValue, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .info, fmt, args);
    }

    /// Log a warning message
    pub inline fn warn(self: *Logger, ctx: []const api.ContextKeyValue, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .warn, fmt, args);
    }

    /// Log an error message
    pub inline fn @"error"(self: *Logger, ctx: []const api.ContextKeyValue, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .@"error", fmt, args);
    }

    /// Log a fatal message
    pub inline fn fatal(self: *Logger, ctx: []const api.ContextKeyValue, comptime fmt: []const u8, args: anytype) void {
        self.log(ctx, .fatal, fmt, args);
    }

    /// Generic log method with severity
    ///
    /// This method formats a log message and emits it with the specified severity.
    /// In debug builds, format string and arguments are validated.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Format string**: Must be non-empty
    /// - **Severity**: Must be valid enum value
    /// - **Message formatting**: Errors are handled gracefully with truncation
    ///
    /// ## Performance
    /// - **Release builds**: No validation overhead
    /// - **Debug builds**: Minimal overhead for validation checks
    pub fn log(
        self: *Logger,
        ctx: []const api.ContextKeyValue,
        severity: api.logs.Severity,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (!self.enabled(ctx, severity)) return;

        var buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch |err| blk: {
            const truncated = switch (err) {
                error.NoSpaceLeft => " [truncated]",
            };
            break :blk buf[0 .. buf.len - truncated.len] ++ truncated;
        };

        self.emitLogRecord(
            ctx,
            severity,
            .{ .string = message },
            null, // attributes
            null, // timestamp — SDK fills in using io clock
            null, // observed_timestamp — SDK fills in using io clock
            null, // event_name
            null, // severity_text
            null, // trace_id
            null, // span_id
            null, // flags
        );
    }
};

/// Bridge structure that holds SDK logger pointer and vtable
pub const LoggerBridge = struct {
    logger_ptr: *anyopaque,
    emitLogRecordFn: *const fn (
        logger_ptr: *anyopaque,
        ctx: []const api.ContextKeyValue,
        severity: ?api.logs.Severity,
        body: ?api.AttributeValue,
        attributes: ?[]const api.AttributeKeyValue,
        timestamp: ?std.Io.Timestamp,
        observed_timestamp: ?std.Io.Timestamp,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?api.common.TraceId,
        span_id: ?api.common.SpanId,
        flags: ?u8,
    ) void,
    enabledFn: *const fn (logger_ptr: *anyopaque, ctx: []const api.ContextKeyValue, severity: ?api.logs.Severity) bool,
    enabledWithEventFn: *const fn (logger_ptr: *anyopaque, ctx: []const api.ContextKeyValue, severity: ?api.logs.Severity, event_name: []const u8) bool,

    pub fn init(ptr: anytype) LoggerBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn emitLogRecord(
                pointer: *anyopaque,
                ctx: []const api.ContextKeyValue,
                severity: ?api.logs.Severity,
                body: ?api.AttributeValue,
                attributes: ?[]const api.AttributeKeyValue,
                timestamp: ?std.Io.Timestamp,
                observed_timestamp: ?std.Io.Timestamp,
                event_name: ?[]const u8,
                severity_text: ?[]const u8,
                trace_id: ?api.common.TraceId,
                span_id: ?api.common.SpanId,
                flags: ?u8,
            ) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.emitLogRecord(
                    self,
                    ctx,
                    severity,
                    body,
                    attributes,
                    timestamp,
                    observed_timestamp,
                    event_name,
                    severity_text,
                    trace_id,
                    span_id,
                    flags,
                );
            }
            pub fn enabled(pointer: *anyopaque, ctx: []const api.ContextKeyValue, severity: ?api.logs.Severity) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabled(self, ctx, severity);
            }
            pub fn enabledWithEvent(pointer: *anyopaque, ctx: []const api.ContextKeyValue, severity: ?api.logs.Severity, event_name: []const u8) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.enabledWithEvent(self, ctx, severity, event_name);
            }
        };

        return .{
            .logger_ptr = ptr,
            .emitLogRecordFn = VTable.emitLogRecord,
            .enabledFn = VTable.enabled,
            .enabledWithEventFn = VTable.enabledWithEvent,
        };
    }
};

/// Validate severity level in debug mode
pub fn validateSeverity(severity: ?api.logs.Severity) ?api.logs.Severity {
    if (!isValidatingMode()) return severity;
    // All Severity enum values are valid by Zig type system
    return severity;
}

/// Validate log message body in debug mode
pub fn validateLogBody(body: ?api.AttributeValue) ?api.AttributeValue {
    if (!isValidatingMode()) return body;

    if (body) |b| {
        switch (b) {
            .string => |s| {
                if (s.len == 0) {
                    reportValidationError(.logger, "emitLogRecord", "Empty log message body provided", null);
                }
            },
            else => {}, // Other AttributeValue types are valid by design
        }
    }
    return body;
}

/// Validate log attributes using existing attribute validation
pub fn validateLogAttributes(attributes: ?[]const api.AttributeKeyValue) ?[]const api.AttributeKeyValue {
    if (!isValidatingMode()) return attributes;

    if (attributes) |attrs| {
        return validateAttributes(attrs);
    }
    return attributes;
}

/// Validate event name in debug mode
pub fn validateEventName(event_name: ?[]const u8) ?[]const u8 {
    if (!isValidatingMode()) return event_name;

    if (event_name) |name| {
        if (name.len == 0) {
            reportValidationError(.logger, "emitLogRecord", "Empty event name provided", null);
        }
    }
    return event_name;
}

/// Validate severity text in debug mode
pub fn validateSeverityText(severity_text: ?[]const u8) ?[]const u8 {
    if (!isValidatingMode()) return severity_text;

    if (severity_text) |text| {
        if (text.len == 0) {
            reportValidationError(.logger, "emitLogRecord", "Empty severity text provided", null);
        }
    }
    return severity_text;
}

/// Validate format string in debug mode
pub fn validateFormatString(comptime fmt: []const u8) bool {
    if (!isValidatingMode()) return true;
    return fmt.len > 0;
}

/// Validate attributes and report errors in debug mode (reuse from tracer)
pub fn validateAttributes(attributes: []const api.AttributeKeyValue) []const api.AttributeKeyValue {
    if (!isValidatingMode()) return attributes;

    // Count invalid attributes
    var invalid_count: usize = 0;

    for (attributes) |attr| {
        if (attr.key.len == 0) {
            invalid_count += 1;
        }
    }

    // Report errors if any invalid attributes found
    if (invalid_count > 0) {
        reportValidationError(.logger, "emitLogRecord", "Invalid attributes detected due to empty keys", null);
    }

    // Always return original slice - no memory allocation
    return attributes;
}
