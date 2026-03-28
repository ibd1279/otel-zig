const std = @import("std");
const api = @import("otel-api");
const sdk = struct {
    const logs = struct {
        const LogRecord = @import("log_record.zig").LogRecord;
        const LoggerProvider = @import("logger_provider.zig").LoggerProvider;
    };
};

const default_severity_when_unknown: api.logs.Severity = .debug;

/// Basic logger implementation with configurable severity and handler
pub const Logger = struct {
    provider: *sdk.logs.LoggerProvider, // non-owning
    scope: api.common.InstrumentationScope, // non-owning
    is_shutdown: std.atomic.Value(bool),
    min_severity: std.atomic.Value(api.logs.Severity),

    pub fn init(
        provider_ptr: *sdk.logs.LoggerProvider,
        instrument_scope: api.common.InstrumentationScope,
        min_severity: api.logs.Severity,
    ) Logger {
        return .{
            .provider = provider_ptr, // io is accessed via provider.io
            .scope = instrument_scope,
            .is_shutdown = .init(false),
            .min_severity = .init(min_severity),
        };
    }

    pub fn deinit(self: *Logger) void {
        _ = self;
    }

    pub fn shutdown(self: *Logger) void {
        self.is_shutdown.store(true, .release);
    }

    pub inline fn emitLogRecord(
        self: *Logger,
        ctx: []const api.ContextKeyValue,
        severity: ?api.logs.Severity,
        body: ?api.common.AttributeValue,
        attributes: ?[]const api.AttributeKeyValue,
        timestamp: ?std.Io.Timestamp,
        observed_timestamp: ?std.Io.Timestamp,
        event_name: ?[]const u8,
        severity_text: ?[]const u8,
        trace_id: ?api.common.TraceId,
        span_id: ?api.common.SpanId,
        flags: ?u8,
    ) void {
        if (self.is_shutdown.load(.unordered)) {
            return;
        }

        // Validate parameters in debug mode
        const validated_severity = api.logs.validateSeverity(severity);
        const validated_body = api.logs.validateLogBody(body);
        const validated_attributes = api.logs.validateLogAttributes(attributes);
        const validated_event_name = api.logs.validateEventName(event_name);
        const validated_severity_text = api.logs.validateSeverityText(severity_text);
        const validated_trace_id = api.common.validateTraceId(trace_id);
        const validated_span_id = api.common.validateSpanId(span_id);
        const validated_flags = api.common.validateTraceFlags(flags);

        const record_severity = validated_severity orelse default_severity_when_unknown;

        // Check severity filtering
        //
        // assumes logging is less likely to be enabled in release modes.
        const branch_hint = comptime switch (@import("builtin").mode) {
            .Debug => std.builtin.BranchHint.unpredictable,
            else => std.builtin.BranchHint.unlikely,
        };
        if (self.enabled(ctx, record_severity)) {
            @branchHint(branch_hint);

            const span_context = api.trace.trace_context.getActiveSpanContext(ctx);
            const tid = validated_trace_id orelse if (span_context) |span_ctx| span_ctx.trace_id else null;
            const sid = validated_span_id orelse if (span_context) |span_ctx| span_ctx.span_id else null;
            const tf = validated_flags orelse if (span_context) |span_ctx| span_ctx.trace_flags else null;

            // Fill in timestamps from io clock if not provided by caller
            const now = std.Io.Clock.real.now(self.provider.io) catch std.Io.Timestamp.zero;
            // Construct LogRecord from individual parameters
            const record = sdk.logs.LogRecord{
                .timestamp = timestamp,
                .observed_timestamp = observed_timestamp orelse now,
                .severity_number = record_severity,
                .severity_text = validated_severity_text,
                .body = validated_body,
                .event_name = validated_event_name,
                .attributes = validated_attributes orelse &[_]api.AttributeKeyValue{},
                .trace_id = tid,
                .span_id = sid,
                .flags = tf,
                .instrumentation_scope = self.scope,
            };

            // This iteration should be safe, as the processors are
            // not able to be changed after the initial setup.
            for (self.provider.processors.items) |processor| {
                // onEmit should be thread safe, and make copies of the
                // LogRecord if they need to operate async.
                processor.onEmit(record, ctx, self.provider.resource);
            }
        }
    }

    pub inline fn enabled(self: *const Logger, ctx: []const api.ContextKeyValue, severity: ?api.logs.Severity) bool {
        if (self.is_shutdown.load(.unordered)) {
            return false;
        }

        // Use INFO level as default when severity is null
        const actual_severity = severity orelse default_severity_when_unknown;

        // Compare severity levels for filtering
        const min_severity = self.min_severity.load(.monotonic);
        if (@intFromEnum(actual_severity) < @intFromEnum(min_severity)) {
            return false;
        }

        // Check if there are any processors (spec requirement)
        if (self.provider.processors.items.len == 0) {
            return false;
        }

        // Check processors per spec: only return false if ALL processors return false
        for (self.provider.processors.items) |processor| {
            if (processor.enabled(ctx, self.scope, actual_severity, null)) {
                return true; // At least one processor wants this record
            }
        }

        // All processors returned false
        return false;
    }

    pub inline fn enabledWithEvent(
        self: *const Logger,
        ctx: []const api.ContextKeyValue,
        severity: ?api.logs.Severity,
        event_name: []const u8,
    ) bool {
        if (self.is_shutdown.load(.unordered)) {
            return false;
        }

        // Use INFO level as default when severity is null
        const actual_severity = severity orelse .info;

        // Compare severity levels for filtering
        const min_severity = self.min_severity.load(.monotonic);
        if (@intFromEnum(actual_severity) < @intFromEnum(min_severity)) {
            return false;
        }

        // Check if there are any processors (spec requirement)
        if (self.provider.processors.items.len == 0) {
            return false;
        }

        // Check processors per spec: only return false if ALL processors return false
        for (self.provider.processors.items) |processor| {
            if (processor.enabled(ctx, self.scope, actual_severity, event_name)) {
                return true; // At least one processor wants this record
            }
        }

        // All processors returned false
        return false;
    }

    pub inline fn logger(self: *Logger) api.logs.Logger {
        return api.logs.Logger{
            .bridge = api.logs.LoggerBridge.init(self),
        };
    }
};
