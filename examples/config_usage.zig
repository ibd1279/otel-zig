//! OpenTelemetry Configuration API Usage Example
//!
//! This example demonstrates how to use the OpenTelemetry Configuration API
//! to read instrumentation configuration in a type-safe manner.
//!
//! Run with: zig run --dep "otel-api" -Mroot=examples/config_usage.zig -Motel-api=src/api/root.zig

const std = @import("std");
const otel_api = @import("otel-api");

// Example HTTP client instrumentation library
const HttpClientInstrumentation = struct {
    config_provider: *const otel_api.config.ConfigProvider,

    pub fn init(config_provider: *const otel_api.config.ConfigProvider) HttpClientInstrumentation {
        return .{ .config_provider = config_provider };
    }

    pub fn configureFromProvider(self: *const HttpClientInstrumentation) HttpClientConfig {
        // Get instrumentation configuration
        if (self.config_provider.getInstrumentationConfig()) |config| {
            // Extract configuration values with defaults
            const timeout = config.get("timeout_ms").asInt() orelse 30000;
            const enabled = config.get("enabled").asBool() orelse true;
            const debug_mode = config.get("debug_mode").asBool() orelse false;

            // Extract headers to capture
            const request_headers = config.get("request_headers").asStringArray() orelse &[_][]const u8{};
            const response_headers = config.get("response_headers").asStringArray() orelse &[_][]const u8{};

            return HttpClientConfig{
                .timeout_ms = timeout,
                .enabled = enabled,
                .debug_enabled = debug_mode,
                .request_headers = request_headers,
                .response_headers = response_headers,
            };
        } else {
            // No configuration available, use defaults
            return HttpClientConfig{};
        }
    }
};

// Configuration structure for HTTP client
const HttpClientConfig = struct {
    timeout_ms: i64 = 30000,
    enabled: bool = true,
    debug_enabled: bool = false,
    request_headers: []const []const u8 = &[_][]const u8{},
    response_headers: []const []const u8 = &[_][]const u8{},

    pub fn print(self: HttpClientConfig) void {
        std.debug.print("HTTP Client Configuration:\n", .{});
        std.debug.print("  Timeout: {}ms\n", .{self.timeout_ms});
        std.debug.print("  Enabled: {}\n", .{self.enabled});
        std.debug.print("  Debug: {}\n", .{self.debug_enabled});

        std.debug.print("  Request Headers to Capture ({}):\n", .{self.request_headers.len});
        for (self.request_headers) |header| {
            std.debug.print("    - {s}\n", .{header});
        }

        std.debug.print("  Response Headers to Capture ({}):\n", .{self.response_headers.len});
        for (self.response_headers) |header| {
            std.debug.print("    - {s}\n", .{header});
        }
    }
};

// Mock SDK implementation for demonstration
const MockSdkConfigProvider = struct {
    const Self = @This();

    // Headers arrays that will persist
    const request_headers = [_][]const u8{ "Content-Type", "Accept", "Authorization" };
    const response_headers = [_][]const u8{ "Content-Type", "Content-Length" };

    pub fn getInstrumentationConfig(self: *const Self) ?otel_api.config.ConfigProperties {
        _ = self;
        return otel_api.config.ConfigProperties{ .bridge = otel_api.config.ConfigPropertiesBridge.init(&config_impl) };
    }

    const ConfigImpl = struct {
        pub fn get(self: *const @This(), key: []const u8) otel_api.config.ConfigValue {
            _ = self;
            if (std.mem.eql(u8, key, "timeout_ms")) {
                return otel_api.config.ConfigValue{ .int = 5000 };
            } else if (std.mem.eql(u8, key, "enabled")) {
                return otel_api.config.ConfigValue{ .bool = true };
            } else if (std.mem.eql(u8, key, "debug_mode")) {
                return otel_api.config.ConfigValue{ .bool = false };
            } else if (std.mem.eql(u8, key, "request_headers")) {
                return otel_api.config.ConfigValue{ .string_array = &request_headers };
            } else if (std.mem.eql(u8, key, "response_headers")) {
                return otel_api.config.ConfigValue{ .string_array = &response_headers };
            }
            return .not_set;
        }
    };

    const config_impl = ConfigImpl{};
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("OpenTelemetry Configuration API Example\n", .{});
    std.debug.print("=====================================\n\n", .{});

    // 1. Create a mock SDK configuration provider
    const mock_sdk = MockSdkConfigProvider{};
    const config_provider = otel_api.config.ConfigProvider{ .bridge = otel_api.config.ConfigProviderBridge.init(&mock_sdk) };

    std.debug.print("1. Created mock SDK configuration provider\n\n", .{});

    // 2. Configure HTTP client instrumentation using ConfigProvider
    const http_instrumentation = HttpClientInstrumentation.init(&config_provider);
    const http_config = http_instrumentation.configureFromProvider();

    std.debug.print("2. Configured HTTP client from provider:\n", .{});
    http_config.print();
    std.debug.print("\n", .{});

    // 3. Demonstrate configuration state checking
    std.debug.print("3. Configuration state examples:\n", .{});

    if (config_provider.getInstrumentationConfig()) |config| {
        // Check timeout setting
        const timeout_setting = config.get("timeout_ms");
        if (timeout_setting.isSet()) {
            std.debug.print("   ✓ Timeout is configured: {}ms\n", .{timeout_setting.asInt().?});
        } else {
            std.debug.print("   ✗ Timeout is not configured\n", .{});
        }

        // Check enabled setting
        const enabled_setting = config.get("enabled");
        if (enabled_setting.isSet()) {
            std.debug.print("   ✓ Enabled is configured: {}\n", .{enabled_setting.asBool().?});
        } else {
            std.debug.print("   ✗ Enabled is not configured\n", .{});
        }

        // Check missing setting
        const missing_setting = config.get("nonexistent_setting");
        if (missing_setting.isSet()) {
            std.debug.print("   ✗ Missing setting is configured\n", .{});
        } else {
            std.debug.print("   ✓ Missing setting is not configured (expected)\n", .{});
        }

        // Demonstrate null vs not_set difference
        const debug_setting = config.get("debug_mode");
        std.debug.print("   Debug setting - isSet: {}, isNull: {}, value: {}\n", .{
            debug_setting.isSet(),
            debug_setting.isNull(),
            debug_setting.asBool() orelse false,
        });
    }

    std.debug.print("\n", .{});

    // 4. Demonstrate noop ConfigProvider
    std.debug.print("4. Noop ConfigProvider example:\n", .{});
    const noop_provider = otel_api.config.ConfigProvider{ .noop = {} };
    const noop_instrumentation = HttpClientInstrumentation.init(&noop_provider);
    const noop_config = noop_instrumentation.configureFromProvider();

    std.debug.print("   Using noop provider (falls back to defaults):\n", .{});
    noop_config.print();

    std.debug.print("\n5. Chaining example (missing path):\n", .{});
    if (config_provider.getInstrumentationConfig()) |config| {
        const nested_missing = config.get("missing").get("nested").get("path");
        std.debug.print("   Nested missing path - isSet: {}\n", .{nested_missing.isSet()});
    }

    std.debug.print("\nExample completed successfully!\n", .{});
}
