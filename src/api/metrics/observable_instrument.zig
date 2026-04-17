//! OpenTelemetry Observable/Async Metric Instruments API
//!
//! This module defines the observable metric instrument types and callback mechanisms.
//! Observable instruments use callbacks to collect measurements at collection time,
//! rather than recording measurements synchronously.
//!
//! The API provides interfaces for:
//! - Observable instruments (ObservableCounter, ObservableGauge, ObservableUpDownCounter)
//! - Callback registration and management
//! - Measurement collection interfaces
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md#asynchronous-instrument-api

const std = @import("std");

// Import from relative paths
const Context = @import("../context/root.zig").Context;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const reportError = @import("../common/error_handler.zig").reportError;

/// Async Instrument for (un-)registering callbacks against.
pub fn ObservableInstrument(comptime T: type) type {
    comptime switch (T) {
        i64, f64 => {},
        else => @compileError("ObservableInstrument must be of type i64 or f64"),
    };

    return union(enum) {
        const Self = @This();

        noop: []const u8,
        bridge: AsyncInstrumentBridge(T),

        /// Get the name of this instrument
        pub inline fn getName(self: *const @This()) []const u8 {
            return switch (self.*) {
                .noop => |name| name,
                .bridge => |bridge| bridge.getName(),
            };
        }

        /// Check if this instrument is enabled for recording measurements
        pub inline fn enabled(self: *const @This()) bool {
            return switch (self.*) {
                .noop => false,
                .bridge => |bridge| bridge.enabled(),
            };
        }

        /// Register a callback with state
        pub inline fn registerCallback(
            self: *const @This(),
            comptime StateType: type,
            callback: ObservableCallback(T, .state),
            state: *StateType,
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop,
                .bridge => |bridge| {
                    const type_erased = createTypeErasedCallback(T, StateType, callback, state);
                    return bridge.registerCallback(type_erased);
                },
            };
        }

        /// Register a callback without state
        pub inline fn registerCallbackNoState(
            self: *const @This(),
            callback: ObservableCallback(T, .stateless),
        ) !CallbackHandle {
            return switch (self.*) {
                .noop => CallbackHandle.noop,
                .bridge => |bridge| {
                    const type_erased = TypeErasedCallback(T){ .stateless = callback };
                    return bridge.registerCallback(type_erased);
                },
            };
        }
    };
}

/// Callback function type for observable instruments with state
/// StateType: The type of state passed to the callback
/// T: The value type (i64 or f64)
/// CbType: Does the Callback Require State.
pub fn ObservableCallback(comptime T: type, comptime CbType: ObservableCallbackType) type {
    return switch (CbType) {
        .state => *const fn (allocator: std.mem.Allocator, result: *ObservableResult(T), state: *anyopaque) void,
        .stateless => *const fn (allocator: std.mem.Allocator, result: *ObservableResult(T)) void,
    };
}

/// Type-erased callback for internal storage
/// T: The value type (i64 or f64)
pub fn TypeErasedCallback(comptime T: type) type {
    return union(enum) {
        state: struct {
            callback_fn: ObservableCallback(T, .state),
            state: *anyopaque,
        },
        stateless: ObservableCallback(T, .stateless),
    };
}

/// Type of callback, does the callback require a state parameter or not?
pub const ObservableCallbackType = enum { state, stateless };

/// Observable result interface for recording measurements from callbacks
pub fn ObservableResult(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Single measurement with value, attributes, and timestamp
        pub const Measurement = struct {
            value: T,
            attributes: []const AttributeKeyValue,
        };

        measurements: std.ArrayList(Measurement),

        /// Initialize a new ObservableResult
        pub const empty = Self{ .measurements = .empty };

        /// Record a measurement with attributes and optional timestamp
        ///
        /// `attributes` is non-owning.
        pub fn observe(
            self: *Self,
            allocator: std.mem.Allocator,
            value: T,
            attributes: []const AttributeKeyValue,
        ) void {
            self.measurements.append(allocator, Measurement{
                .value = value,
                .attributes = attributes,
            }) catch |err| {
                reportError(.{
                    .component = .meter,
                    .context = null,
                    .error_type = .internal,
                    .message = "Unable to append measure",
                    .operation = "ObservableResult.observe",
                    .source_error = err,
                });
            };
        }

        /// Record a measurement without attributes
        pub fn observeValue(self: *Self, allocator: std.mem.Allocator, value: T) void {
            self.observe(allocator, value, &[_]AttributeKeyValue{});
        }

        /// Deinitialize the result
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.measurements.deinit(allocator);
        }
    };
}

/// Handle for managing callback registration and unregistration
pub const CallbackHandle = struct {
    const Self = @This();

    instrument_ptr: ?*anyopaque,
    unregister_fn: ?*const fn (instrument_ptr: *anyopaque, callback_id: u64) void,
    callback_id: u64,

    /// Create a no-op callback handle
    pub const noop: Self = .{
        .instrument_ptr = null,
        .unregister_fn = null,
        .callback_id = 0,
    };

    /// Initialize a callback handle
    pub fn init(
        instrument_ptr: *anyopaque,
        unregister_fn: *const fn (instrument_ptr: *anyopaque, callback_id: u64) void,
        callback_id: u64,
    ) Self {
        return Self{
            .instrument_ptr = instrument_ptr,
            .unregister_fn = unregister_fn,
            .callback_id = callback_id,
        };
    }

    /// Unregister the callback
    pub fn unregister(self: *const Self) void {
        if (self.instrument_ptr != null and self.unregister_fn != null) {
            self.unregister_fn.?(self.instrument_ptr.?, self.callback_id);
        }
    }
};

/// Create type-erased callback for stateful callbacks
pub fn createTypeErasedCallback(
    comptime T: type,
    comptime StateType: type,
    callback: ObservableCallback(T, .state),
    state: *StateType,
) TypeErasedCallback(T) {
    // For now, just store the callback pointer directly
    // The SDK will handle proper type casting and invocation
    return TypeErasedCallback(T){ .state = .{
        .callback_fn = @ptrCast(callback),
        .state = state,
    } };
}

/// Bridge structure for connecting API to SDK implementations
pub fn AsyncInstrumentBridge(comptime T: type) type {
    return struct {
        const Self = @This();

        instrument_ptr: *anyopaque,
        getNameFn: *const fn (instrument_ptr: *anyopaque) []const u8,
        enabledFn: *const fn (instrument_ptr: *anyopaque) bool,
        registerCallbackFn: *const fn (instrument_ptr: *anyopaque, callback: TypeErasedCallback(T)) anyerror!CallbackHandle,

        /// Get the name of this instrument
        pub fn getName(self: *const Self) []const u8 {
            return self.getNameFn(self.instrument_ptr);
        }

        /// Check if this instrument is enabled
        pub fn enabled(self: *const Self) bool {
            return self.enabledFn(self.instrument_ptr);
        }

        /// Register a callback
        pub fn registerCallback(self: *const Self, callback: TypeErasedCallback(T)) !CallbackHandle {
            return self.registerCallbackFn(self.instrument_ptr, callback);
        }

        /// Initialize bridge with SDK instrument
        pub fn init(ptr: anytype) Self {
            const PtrType = @TypeOf(ptr);
            const ptr_info = @typeInfo(PtrType);

            const VTable = struct {
                pub fn getName(pointer: *anyopaque) []const u8 {
                    const self: PtrType = @ptrCast(@alignCast(pointer));
                    return ptr_info.pointer.child.getName(self);
                }

                pub fn enabled(pointer: *anyopaque) bool {
                    const self: PtrType = @ptrCast(@alignCast(pointer));
                    return ptr_info.pointer.child.enabled(self);
                }

                pub fn registerCallback(pointer: *anyopaque, callback: TypeErasedCallback(T)) anyerror!CallbackHandle {
                    const self: PtrType = @ptrCast(@alignCast(pointer));
                    return ptr_info.pointer.child.registerCallback(self, callback);
                }
            };

            return .{
                .instrument_ptr = ptr,
                .getNameFn = VTable.getName,
                .enabledFn = VTable.enabled,
                .registerCallbackFn = VTable.registerCallback,
            };
        }
    };
}

test "ObservableResult basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var result = ObservableResult(i64).empty;
    defer result.deinit(allocator);

    result.observeValue(allocator, 42);
    result.observe(allocator, 100, &[_]AttributeKeyValue{
        .{ .key = "test", .value = .{ .string = "value" } },
    });

    try testing.expectEqual(@as(usize, 2), result.measurements.items.len);
    try testing.expectEqual(@as(i64, 42), result.measurements.items[0].value);
    try testing.expectEqual(@as(i64, 100), result.measurements.items[1].value);
}

test "observable instruments enabled method" {
    const testing = std.testing;

    // Test noop instruments return false
    var noop_counter = ObservableInstrument(i64){ .noop = "test" };
    try testing.expect(!noop_counter.enabled());

    var noop_gauge = ObservableInstrument(i64){ .noop = "test" };
    try testing.expect(!noop_gauge.enabled());

    var noop_updown = ObservableInstrument(i64){ .noop = "test" };
    try testing.expect(!noop_updown.enabled());
}

test "callback handle noop functionality" {
    const testing = std.testing;

    var handle = CallbackHandle.noop;
    try testing.expect(handle.instrument_ptr == null);
    try testing.expect(handle.unregister_fn == null);
    try testing.expectEqual(@as(u64, 0), handle.callback_id);

    // Should not crash
    handle.unregister();
}
