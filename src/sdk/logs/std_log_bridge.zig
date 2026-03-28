//! std.log Bridge for OpenTelemetry
//!
//! This module provides a bridge between Zig's standard logging system (std.log)
//! and OpenTelemetry structured logging. It allows existing std.log code to work
//! unchanged while automatically emitting OpenTelemetry log records.
//!
//! ## Usage
//!
//! In your application's std_options:
//! ```zig
//! const std_log_bridge = @import("otel-sdk").std_log_bridge;
//!
//! pub const std_options = .{
//!     .log_level = .debug,
//!     .logFn = std_log_bridge.otelLogFn,
//! };
//! ```
//!
//! Then initialize the bridge after setting up your OTel providers:
//! ```zig
//! try std_log_bridge.init(.{});
//! defer std_log_bridge.deinit();
//! ```

const std = @import("std");
const api = @import("otel-api");

/// Configuration for the std.log bridge
pub const BridgeConfig = struct {
    /// Whether the bridge is enabled (if false, falls back to std.log.defaultLog)
    enabled: bool = true,

    /// Whether to include the std.log scope as an attribute
    include_scope_attribute: bool = true,

    /// Instrumentation scope name for all std.log messages
    instrumentation_scope_name: []const u8 = "std.log",

    /// Instrumentation scope version
    instrumentation_scope_version: ?[]const u8 = null,
};

/// Bridge state - kept minimal for performance
const BridgeState = struct {
    config: BridgeConfig,
    context: []api.ContextKeyValue,
    instrumentation_scope: api.InstrumentationScope,
    initialized: std.atomic.Value(bool),
};

/// Global bridge state
var bridge_state: BridgeState = undefined;
var bridge_mutex = std.Thread.Mutex{};

/// Initialize the std.log bridge
pub fn init(config: BridgeConfig) !void {
    bridge_mutex.lock();
    defer bridge_mutex.unlock();

    if (bridge_state.initialized.load(.acquire)) return;

    // Create context - using page allocator since this is global state
    const context = try api.ContextKeyValue.initOwnedSlice(std.heap.page_allocator, &.{});
    errdefer api.ContextKeyValue.deinitOwnedSlice(std.heap.page_allocator, context);

    // Create instrumentation scope
    const instrumentation_scope = api.InstrumentationScope{
        .name = config.instrumentation_scope_name,
        .version = config.instrumentation_scope_version,
    };

    bridge_state = BridgeState{
        .config = config,
        .context = context,
        .instrumentation_scope = instrumentation_scope,
        .initialized = std.atomic.Value(bool).init(false),
    };

    bridge_state.initialized.store(true, .release);
}

/// Deinitialize the std.log bridge
pub fn deinit() void {
    bridge_mutex.lock();
    defer bridge_mutex.unlock();

    if (!bridge_state.initialized.load(.acquire)) return;

    api.ContextKeyValue.deinitOwnedSlice(std.heap.page_allocator, bridge_state.context);
    bridge_state.initialized.store(false, .release);
}

/// Update bridge configuration at runtime
pub fn updateConfig(config: BridgeConfig) void {
    bridge_mutex.lock();
    defer bridge_mutex.unlock();

    if (bridge_state.initialized.load(.acquire)) {
        bridge_state.config = config;
    }
}

/// Map std.log.Level to OpenTelemetry Severity
fn mapLogLevelToSeverity(level: std.log.Level) api.logs.Severity {
    return switch (level) {
        .err => .@"error", // std.log.err -> OTel ERROR (17)
        .warn => .warn, // std.log.warn -> OTel WARN (13)
        .info => .info, // std.log.info -> OTel INFO (9)
        .debug => .debug, // std.log.debug -> OTel DEBUG (5)
    };
}

/// OpenTelemetry logFn implementation
pub fn otelLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Fast path: if bridge not initialized or disabled, use default logging
    if (!bridge_state.initialized.load(.acquire) or !bridge_state.config.enabled) {
        std.log.defaultLog(level, scope, format, args);
        return;
    }

    // Try to perform OTel logging, fall back to default on any error
    otelLogImpl(level, scope, format, args) catch {
        std.log.defaultLog(level, scope, format, args);
    };
}

/// Internal OTel logging implementation
fn otelLogImpl(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) !void {
    // Get logger from global provider
    const logger_provider = api.getGlobalLoggerProvider();
    var logger = logger_provider.getLoggerWithScope(bridge_state.instrumentation_scope) catch {
        return error.LoggerCreationFailed;
    };

    // Map severity
    const severity = mapLogLevelToSeverity(level);

    // Early return if logging not enabled for this level
    if (!logger.enabled(bridge_state.context, severity)) return;

    // Format message - use stack buffer for efficiency
    var message_buf: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, format, args) catch |err| switch (err) {
        error.NoSpaceLeft => message_buf[0 .. message_buf.len - 12] ++ " [truncated]",
    };

    // TODO: Add scope attributes - simplified for now to avoid type issues
    _ = scope; // Suppress unused parameter warning
    const attributes: ?[]const api.common.AttributeKeyValue = null;

    // Emit log record
    logger.emitLogRecord(
        bridge_state.context,
        severity, // severity
        .{ .string = message }, // body
        attributes, // attributes
        null, // timestamp — SDK fills in via provider.io
        null, // observed_timestamp
        null, // event_name
        null, // severity_text
        null, // trace_id
        null, // span_id
        null, // flags
    );
}

/// Check if the bridge is initialized and enabled
pub fn isEnabled() bool {
    return bridge_state.initialized.load(.acquire) and bridge_state.config.enabled;
}

/// Get current bridge configuration (thread-safe read)
pub fn getConfig() BridgeConfig {
    if (bridge_state.initialized.load(.acquire)) {
        return bridge_state.config;
    }
    return BridgeConfig{};
}

// Tests
test "std.log bridge initialization" {
    const testing = std.testing;

    // Test initialization
    try init(.{});
    defer deinit();

    try testing.expect(isEnabled());

    const config = getConfig();
    try testing.expect(config.enabled);
    try testing.expect(config.include_scope_attribute);
    try testing.expectEqualStrings("std.log", config.instrumentation_scope_name);
}

test "severity mapping" {
    const testing = std.testing;

    try testing.expectEqual(api.logs.Severity.@"error", mapLogLevelToSeverity(.err));
    try testing.expectEqual(api.logs.Severity.warn, mapLogLevelToSeverity(.warn));
    try testing.expectEqual(api.logs.Severity.info, mapLogLevelToSeverity(.info));
    try testing.expectEqual(api.logs.Severity.debug, mapLogLevelToSeverity(.debug));
}

test "config updates" {
    const testing = std.testing;

    try init(.{ .enabled = true });
    defer deinit();

    try testing.expect(isEnabled());

    updateConfig(.{ .enabled = false });
    try testing.expect(!isEnabled());

    updateConfig(.{ .enabled = true });
    try testing.expect(isEnabled());
}

test "fallback behavior" {

    // Test that otelLogFn works even when not initialized
    // This should not crash and should fall back to std.log.defaultLog
    otelLogFn(.info, .testing, "Test message {}", .{42});

    // Initialize and test normal operation
    try init(.{});
    defer deinit();

    otelLogFn(.info, .testing, "Test message {}", .{42});
}
