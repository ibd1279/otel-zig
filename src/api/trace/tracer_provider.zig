//! OpenTelemetry Tracer Provider API
//!
//! This module defines the TracerProvider interface for creating Tracer instances.
//! TracerProvider manages the lifecycle of tracers and ensures consistent
//! tracer instances for the same instrumentation scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#tracerprovider

const std = @import("std");
const Tracer = @import("tracer.zig").Tracer;
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;

/// TracerProvider interface using tagged union for polymorphism
pub const TracerProvider = union(enum) {
    noop: void,
    bridge: TracerProviderBridge, // SDK provider bridge

    /// Get or create a tracer with instrumentation scope (OpenTelemetry API specification compliant)
    ///
    /// Implementations must return the same tracer for the same scope.
    pub inline fn getTracerWithScope(self: *const TracerProvider, scope: InstrumentationScope) !Tracer {
        return switch (self.*) {
            .noop => Tracer{ .noop = {} },
            .bridge => |*bridge| bridge.getTracerWithScopeFn(bridge.provider_ptr, scope),
        };
    }
};

/// Bridge structure that holds SDK provider pointer and vtable
pub const TracerProviderBridge = struct {
    provider_ptr: *anyopaque,
    getTracerWithScopeFn: *const fn (provider_ptr: *anyopaque, scope: InstrumentationScope) anyerror!Tracer,

    pub fn init(ptr: anytype) TracerProviderBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getTracerWithScope(pointer: *anyopaque, scope: InstrumentationScope) anyerror!Tracer {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getTracerWithScope(self, scope);
            }
        };

        return .{
            .provider_ptr = ptr,
            .getTracerWithScopeFn = VTable.getTracerWithScope,
        };
    }
};
