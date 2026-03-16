//! OpenTelemetry SDK Resource Detector
//!
//! This module provides resource detection capabilities for automatically
//! discovering resource attributes from the environment, process, and host.
//!
//! ## Components
//! - `ResourceDetector` - Interface for resource detection
//! - `DefaultDetector` - Combines multiple detectors
//! - `ProcessDetector` - Detects process attributes (PID, executable name, etc.)
//! - `HostDetector` - Detects host attributes (hostname, OS, etc.)
//! - `EnvironmentDetector` - Detects from OTEL_RESOURCE_ATTRIBUTES env var
//!
//! ## Usage
//! ```zig
//! const resource = try detectResource(allocator);
//! defer resource.deinit();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const api = @import("otel-api");
const sdk = struct {
    const Resource = @import("resource.zig").Resource;
};

const AttributeValue = api.common.AttributeValue;
const AttributeKeyValue = api.common.AttributeKeyValue;
const AttributeBuilder = api.common.AttributeBuilder;

/// Resource detector interface using tagged union
pub const ResourceDetector = union(enum) {
    default: DefaultDetector,
    process: ProcessDetector,
    host: HostDetector,
    environment: EnvironmentDetector,
    custom: CustomDetector,

    /// Detect resource attributes
    pub fn detect(self: *ResourceDetector, allocator: std.mem.Allocator) anyerror!sdk.Resource {
        return switch (self.*) {
            .default => |*detector| detector.detect(allocator),
            .process => |*detector| detector.detect(allocator),
            .host => |*detector| detector.detect(allocator),
            .environment => |*detector| detector.detect(allocator),
            .custom => |*detector| detector.detect(allocator),
        };
    }
};

/// Default detector that combines multiple detectors
pub const DefaultDetector = struct {
    detectors: []ResourceDetector,

    pub fn init(detectors: []ResourceDetector) DefaultDetector {
        return .{ .detectors = detectors };
    }

    pub fn detect(self: *DefaultDetector, allocator: std.mem.Allocator) anyerror!sdk.Resource {
        // An arena is used for detection because some detectors return static strings, others
        // need to copy strings. Assuming all allocation is done with the arena, we don't have
        // to keep track of the memory until the final resource is allocated.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // Run all detectors
        var base = try sdk.Resource.initOwned(arena.allocator(), .default);
        for (self.detectors) |*detector| {
            const detected = try detector.detect(arena.allocator());
            base = try sdk.Resource.initOwnedMerge(arena.allocator(), base, detected);
        }

        // One last copy to move the resource from the arena allocator to the requested allocator.
        return try sdk.Resource.initOwned(allocator, base);
    }
};

/// Process resource detector
pub const ProcessDetector = struct {
    pub fn init() ProcessDetector {
        return .{};
    }

    pub fn detect(self: *ProcessDetector, allocator: std.mem.Allocator) anyerror!sdk.Resource {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var attrs = AttributeBuilder.init(arena.allocator());

        // Get executable path
        switch (builtin.os.tag) {
            .macos => {
                // Detect process attributes
                const pid = std.c.getpid();
                attrs = attrs.add(.{ .key = "process.pid", .value = .{ .int = @intCast(pid) } });

                // Let the arena allocator clean up the memory.
                var size: u32 = std.fs.max_path_bytes;
                // const buf = try arena.allocator().alloc(u8, size);
                const buf = try arena.allocator().allocSentinel(u8, size, 0);

                if (std.c._NSGetExecutablePath(buf, &size) == 0) {
                    const path = std.mem.sliceTo(buf, 0);
                    const basename = std.fs.path.basename(path);
                    attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = path } });
                    attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = basename } });
                }
            },
            .freebsd => {
                // Detect process attributes
                const pid = std.c.getpid();
                attrs = attrs.add(.{ .key = "process.pid", .value = .{ .int = @intCast(pid) } });

                // Try to read executable path from procfs symlink
                var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fs.cwd().readLink("/proc/curproc/file", &exe_buf)) |exe_path| {
                    const exe_path_owned = try arena.allocator().dupe(u8, exe_path);
                    const basename = std.fs.path.basename(exe_path_owned);
                    attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = exe_path_owned } });
                    attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = basename } });
                } else |_| {}
            },
            else => @compileError("unsupported OS."),
        }

        // Command line args (if available)
        if (std.process.argsAlloc(arena.allocator())) |args| {
            if (args.len > 0) {
                attrs = attrs.add(.{ .key = "process.command", .value = .{ .string = args[0] } });
            }
        } else |_| {}

        return try sdk.Resource.initOwnedFromBuilder(allocator, null, &attrs);
    }
};

/// Host resource detector
pub const HostDetector = struct {
    pub fn init() HostDetector {
        return .{};
    }

    pub fn detect(self: *HostDetector, allocator: std.mem.Allocator) anyerror!sdk.Resource {
        _ = self;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var attrs = AttributeBuilder.init(arena.allocator());

        // Detect OS type
        const os_type = switch (builtin.target.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "darwin",
            .freebsd => "freebsd",
            .openbsd => "openbsd",
            .netbsd => "netbsd",
            .dragonfly => "dragonfly",
            else => "unknown",
        };
        attrs = attrs.add(.{ .key = "host.type", .value = .{ .string = os_type } });

        // Detect architecture
        const arch = switch (builtin.target.cpu.arch) {
            .x86_64 => "amd64",
            .x86 => "x86",
            .aarch64 => "arm64",
            .arm => "arm",
            .riscv64 => "riscv64",
            .wasm32 => "wasm32",
            else => "unknown",
        };
        attrs = attrs.add(.{ .key = "host.arch", .value = .{ .string = arch } });

        // Detect host name
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&hostname_buf)) |hostname| {
            attrs = attrs.add(.{ .key = "host.name", .value = .{ .string = hostname } });
        } else |_| {}

        return try sdk.Resource.initOwnedFromBuilder(allocator, null, &attrs);
    }
};

/// Environment variable resource detector
pub const EnvironmentDetector = struct {
    pub fn init() EnvironmentDetector {
        return .{};
    }

    pub fn detect(self: *EnvironmentDetector, allocator: std.mem.Allocator) anyerror!sdk.Resource {
        _ = self;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var attrs = AttributeBuilder.init(arena.allocator());

        // Check OTEL_RESOURCE_ATTRIBUTES
        if (std.process.getEnvVarOwned(arena.allocator(), "OTEL_RESOURCE_ATTRIBUTES")) |env_attrs| {

            // Parse key=value pairs separated by commas
            var iter = std.mem.tokenizeScalar(u8, env_attrs, ',');
            while (iter.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " ");
                if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                    const key = trimmed[0..eq_pos];
                    const value = trimmed[eq_pos + 1 ..];
                    attrs = attrs.add(.{ .key = key, .value = .{ .string = value } });
                }
            }
        } else |_| {}

        // Check OTEL_SERVICE_NAME
        if (std.process.getEnvVarOwned(arena.allocator(), "OTEL_SERVICE_NAME")) |service_name| {
            attrs = attrs.add(.{ .key = "service.name", .value = .{ .string = service_name } });
        } else |_| {}

        return try sdk.Resource.initOwnedFromBuilder(allocator, null, &attrs);
    }
};

/// Custom detector with user-provided implementation
pub const CustomDetector = struct {
    impl: *anyopaque,
    detectFn: *const fn (impl: *anyopaque, allocator: std.mem.Allocator) anyerror!sdk.Resource,

    pub fn init(
        impl: *anyopaque,
        detectFn: *const fn (impl: *anyopaque, allocator: std.mem.Allocator) anyerror!sdk.Resource,
    ) CustomDetector {
        return .{
            .impl = impl,
            .detectFn = detectFn,
        };
    }

    pub fn detect(self: *CustomDetector, allocator: std.mem.Allocator) anyerror!sdk.Resource {
        return self.detectFn(self.impl, allocator);
    }
};

/// Detect resource using all default detectors
pub fn detectResource(allocator: std.mem.Allocator) anyerror!sdk.Resource {
    const process_detector = ResourceDetector{ .process = ProcessDetector.init() };
    const host_detector = ResourceDetector{ .host = HostDetector.init() };
    const env_detector = ResourceDetector{ .environment = EnvironmentDetector.init() };

    var detectors = [_]ResourceDetector{ process_detector, host_detector, env_detector };
    const default_detector = DefaultDetector.init(&detectors);
    var detector = ResourceDetector{ .default = default_detector };

    return detector.detect(allocator);
}

test "HostDetector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var detector = HostDetector.init();
    var resource = try detector.detect(allocator);
    defer resource.deinitOwned(allocator);

    // Should have host.type and host.arch
    try testing.expect(resource.attributes.len >= 2);
    try testing.expectEqualStrings("host.type", resource.attributes[0].key);
    try testing.expectEqualStrings("host.arch", resource.attributes[1].key);
}
