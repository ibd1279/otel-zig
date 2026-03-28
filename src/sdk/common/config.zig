//! OpenTelemetry SDK Configuration
//!
//! This module provides configuration structures and utilities for the SDK.
//! It includes limits for various components and environment variable parsing.

const std = @import("std");

/// Main configuration structure for the SDK
pub const Config = struct {
    /// Resource configuration
    resource_attributes_limit: u32 = 128,
    
    /// Span configuration
    span_limits: SpanLimits = .{},
    
    /// Log record configuration
    log_record_limits: LogRecordLimits = .{},
    
    /// Attribute limits
    attribute_limits: AttributeLimits = .{},
    
    /// Export timeout in milliseconds
    export_timeout_millis: u64 = 30000,
    
    /// Whether to honor OTEL_* environment variables
    honor_env_vars: bool = true,
};

/// General limits configuration
pub const Limits = struct {
    /// Maximum number of attributes
    attribute_count_limit: u32 = 128,
    
    /// Maximum length of attribute string values
    attribute_value_length_limit: ?u32 = null,
};

/// Attribute-specific limits
pub const AttributeLimits = struct {
    /// Maximum number of attributes allowed
    count_limit: u32 = 128,
    
    /// Maximum length of attribute string values (null = unlimited)
    value_length_limit: ?u32 = null,
    
    /// Apply limits to an attribute value
    pub fn applyToValue(self: AttributeLimits, value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        if (self.value_length_limit) |limit| {
            if (value.len > limit) {
                const truncated = try allocator.alloc(u8, limit);
                @memcpy(truncated, value[0..limit]);
                return truncated;
            }
        }
        return value;
    }
};

/// Span-specific limits
pub const SpanLimits = struct {
    /// Maximum number of attributes per span
    attribute_count_limit: u32 = 128,
    
    /// Maximum length of attribute string values
    attribute_value_length_limit: ?u32 = null,
    
    /// Maximum number of events per span
    event_count_limit: u32 = 128,
    
    /// Maximum number of links per span
    link_count_limit: u32 = 128,
    
    /// Maximum number of attributes per event
    event_attribute_count_limit: u32 = 128,
    
    /// Maximum number of attributes per link
    link_attribute_count_limit: u32 = 128,
};

/// Log record-specific limits
pub const LogRecordLimits = struct {
    /// Maximum number of attributes per log record
    attribute_count_limit: u32 = 128,
    
    /// Maximum length of attribute string values
    attribute_value_length_limit: ?u32 = null,
};

/// Environment variable names
pub const EnvironmentVariables = struct {
    pub const OTEL_RESOURCE_ATTRIBUTES = "OTEL_RESOURCE_ATTRIBUTES";
    pub const OTEL_SERVICE_NAME = "OTEL_SERVICE_NAME";
    pub const OTEL_LOG_LEVEL = "OTEL_LOG_LEVEL";
    pub const OTEL_PROPAGATORS = "OTEL_PROPAGATORS";
    pub const OTEL_TRACES_EXPORTER = "OTEL_TRACES_EXPORTER";
    pub const OTEL_METRICS_EXPORTER = "OTEL_METRICS_EXPORTER";
    pub const OTEL_LOGS_EXPORTER = "OTEL_LOGS_EXPORTER";
    pub const OTEL_EXPORTER_OTLP_ENDPOINT = "OTEL_EXPORTER_OTLP_ENDPOINT";
    pub const OTEL_EXPORTER_OTLP_HEADERS = "OTEL_EXPORTER_OTLP_HEADERS";
    pub const OTEL_EXPORTER_OTLP_TIMEOUT = "OTEL_EXPORTER_OTLP_TIMEOUT";
    pub const OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT = "OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT";
    pub const OTEL_SPAN_EVENT_COUNT_LIMIT = "OTEL_SPAN_EVENT_COUNT_LIMIT";
    pub const OTEL_SPAN_LINK_COUNT_LIMIT = "OTEL_SPAN_LINK_COUNT_LIMIT";
    pub const OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT = "OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT";
    pub const OTEL_ATTRIBUTE_COUNT_LIMIT = "OTEL_ATTRIBUTE_COUNT_LIMIT";
};

/// Get an environment variable value (returned slice is owned by page_allocator; caller must free)
pub fn getEnvironmentVariable(name: []const u8) ?[]const u8 {
    // Build a null-terminated name for the C getenv call.
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const cstr = std.c.getenv(name_buf[0..name.len :0]) orelse return null;
    const value = std.mem.sliceTo(cstr, 0);
    return std.heap.page_allocator.dupe(u8, value) catch null;
}

/// Parse an environment variable as a specific type
pub fn parseEnvironmentVariable(comptime T: type, name: []const u8) ?T {
    const value = getEnvironmentVariable(name) orelse return null;
    defer std.heap.page_allocator.free(value);
    
    return switch (T) {
        bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
        u32, u64, i32, i64 => std.fmt.parseInt(T, value, 10) catch null,
        f32, f64 => std.fmt.parseFloat(T, value) catch null,
        []const u8 => value,
        else => @compileError("Unsupported type for environment variable parsing"),
    };
}

/// Create configuration from environment variables
pub fn fromEnvironment(allocator: std.mem.Allocator) !Config {
    _ = allocator;
    
    var config = Config{};
    
    // Parse attribute limits
    if (parseEnvironmentVariable(u32, EnvironmentVariables.OTEL_ATTRIBUTE_COUNT_LIMIT)) |limit| {
        config.attribute_limits.count_limit = limit;
        config.span_limits.attribute_count_limit = limit;
        config.log_record_limits.attribute_count_limit = limit;
    }
    
    if (parseEnvironmentVariable(u32, EnvironmentVariables.OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT)) |limit| {
        config.attribute_limits.value_length_limit = limit;
        config.span_limits.attribute_value_length_limit = limit;
        config.log_record_limits.attribute_value_length_limit = limit;
    }
    
    // Parse span-specific limits
    if (parseEnvironmentVariable(u32, EnvironmentVariables.OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT)) |limit| {
        config.span_limits.attribute_count_limit = limit;
    }
    
    if (parseEnvironmentVariable(u32, EnvironmentVariables.OTEL_SPAN_EVENT_COUNT_LIMIT)) |limit| {
        config.span_limits.event_count_limit = limit;
    }
    
    if (parseEnvironmentVariable(u32, EnvironmentVariables.OTEL_SPAN_LINK_COUNT_LIMIT)) |limit| {
        config.span_limits.link_count_limit = limit;
    }
    
    // Parse export timeout
    if (parseEnvironmentVariable(u64, EnvironmentVariables.OTEL_EXPORTER_OTLP_TIMEOUT)) |timeout| {
        config.export_timeout_millis = timeout;
    }
    
    return config;
}

test "AttributeLimits applyToValue" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const limits = AttributeLimits{
        .count_limit = 10,
        .value_length_limit = 5,
    };
    
    // Test truncation
    const long_value = "Hello, World!";
    const truncated = try limits.applyToValue(long_value, allocator);
    defer allocator.free(truncated);
    try testing.expectEqualStrings("Hello", truncated);
    
    // Test no truncation needed
    const short_value = "Hi";
    const not_truncated = try limits.applyToValue(short_value, allocator);
    try testing.expectEqualStrings("Hi", not_truncated);
}

test "parseEnvironmentVariable" {
    const testing = std.testing;
    
    // Note: This test would need actual environment variables set
    // For now, just test the parsing logic with mock values
    
    // Test boolean parsing
    try testing.expect(parseEnvironmentVariable(bool, "NONEXISTENT_VAR") == null);
    
    // Would need to set environment variables for full testing
    // std.process.setEnvironmentVariable("TEST_BOOL", "true");
    // try testing.expect(parseEnvironmentVariable(bool, "TEST_BOOL") == true);
}

test "Config defaults" {
    const testing = std.testing;
    
    const config = Config{};
    try testing.expectEqual(@as(u32, 128), config.resource_attributes_limit);
    try testing.expectEqual(@as(u32, 128), config.span_limits.attribute_count_limit);
    try testing.expectEqual(@as(u32, 128), config.log_record_limits.attribute_count_limit);
    try testing.expectEqual(@as(u64, 30000), config.export_timeout_millis);
    try testing.expect(config.honor_env_vars);
}

test "SpanLimits" {
    const testing = std.testing;
    
    const limits = SpanLimits{
        .attribute_count_limit = 64,
        .event_count_limit = 32,
        .link_count_limit = 16,
    };
    
    try testing.expectEqual(@as(u32, 64), limits.attribute_count_limit);
    try testing.expectEqual(@as(u32, 32), limits.event_count_limit);
    try testing.expectEqual(@as(u32, 16), limits.link_count_limit);
}