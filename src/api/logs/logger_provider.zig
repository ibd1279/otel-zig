//! OpenTelemetry Logger Provider API
//!
//! This module defines the LoggerProvider interface for creating Logger instances.
//! LoggerProvider manages the lifecycle of loggers and ensures consistent
//! logger instances for the same instrumentation scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/logs/api.md#loggerprovider

const std = @import("std");
const Logger = @import("logger.zig").Logger;
const NoopLogger = @import("logger.zig").NoopLogger;
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;

/// LoggerProvider interface using tagged union for polymorphism
pub const LoggerProvider = union(enum) {
    noop: void,
    bridge: LoggerProviderBridge, // SDK provider bridge

    /// Get or create a logger with direct parameters.
    ///
    /// The provider must make an internal copy of the provided instrumentation scope
    /// and will not take ownership of it.
    pub inline fn getLoggerWithScope(self: *const LoggerProvider, scope: InstrumentationScope) !Logger {
        return switch (self.*) {
            .noop => Logger{ .noop = {} },
            .bridge => |*bridge| bridge.getLoggerWithScopeFn(bridge.provider_ptr, scope),
        };
    }
};

/// Bridge structure that holds SDK provider pointer and vtable
pub const LoggerProviderBridge = struct {
    provider_ptr: *anyopaque,
    getLoggerWithScopeFn: *const fn (provider_ptr: *anyopaque, scope: InstrumentationScope) anyerror!Logger,

    pub fn init(ptr: anytype) LoggerProviderBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getLoggerWithScope(pointer: *anyopaque, scope: InstrumentationScope) anyerror!Logger {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getLoggerWithScope(self, scope);
            }
        };

        return .{
            .provider_ptr = ptr,
            .getLoggerWithScopeFn = VTable.getLoggerWithScope,
        };
    }
};
