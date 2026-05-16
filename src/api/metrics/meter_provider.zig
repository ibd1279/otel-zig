//! OpenTelemetry Meter Provider API
//!
//! This module defines the MeterProvider interface for creating Meter instances.
//! MeterProvider manages the lifecycle of meters and ensures consistent
//! meter instances for the same instrumentation scope.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md#meterprovider

const std = @import("std");

const Meter = @import("meter.zig").Meter;
const Context = @import("../context/root.zig").Context;
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const AttributeValue = @import("../common/root.zig").AttributeValue;

/// MeterProvider interface using tagged union for polymorphism
pub const MeterProvider = union(enum) {
    noop: void,
    bridge: MeterProviderBridge,

    /// Get or create a meter for the given instrumentation scope
    /// Providers are expected to return the same meter when provided
    /// an identical scope.
    pub inline fn getMeterWithScope(self: *const MeterProvider, scope: InstrumentationScope) Meter {
        return switch (self.*) {
            .noop => Meter{ .noop = scope },
            .bridge => |*bridge| bridge.getMeterWithScopeFn(bridge.provider_ptr, scope),
        };
    }
};

/// Bridge structure that holds SDK provider pointer and vtable
pub const MeterProviderBridge = struct {
    provider_ptr: *anyopaque,
    getMeterWithScopeFn: *const fn (provider_ptr: *anyopaque, scope: InstrumentationScope) Meter,

    pub fn init(ptr: anytype) MeterProviderBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn getMeterWithScope(pointer: *anyopaque, scope: InstrumentationScope) Meter {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.getMeterWithScope(self, scope);
            }
        };

        return .{
            .provider_ptr = ptr,
            .getMeterWithScopeFn = VTable.getMeterWithScope,
        };
    }
};
