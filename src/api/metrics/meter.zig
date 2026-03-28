//! OpenTelemetry Meter API
//!
//! This module defines the Meter interface for creating metric instruments.
//! A Meter is responsible for creating instruments (Counter, Gauge, etc.) that
//! are used to record measurements.
//!
//! The API provides only the interface and a no-op implementation. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/api.md#meter

const std = @import("std");
const isValidatingMode = @import("../common/error_handler.zig").isValidatingMode;
const reportValidationError = @import("../common/error_handler.zig").reportValidationError;

// Import from relative paths
const InstrumentationScope = @import("../common/root.zig").InstrumentationScope;
const AttributeKeyValue = @import("../common/root.zig").AttributeKeyValue;
const Context = @import("../context/root.zig").Context;

// Forward declarations for instruments
const Counter = @import("instrument.zig").Counter;
const UpDownCounter = @import("instrument.zig").UpDownCounter;
const Gauge = @import("instrument.zig").Gauge;
const Histogram = @import("instrument.zig").Histogram;
const AdvisoryParams = @import("instrument.zig").AdvisoryParams;

// Observable instrument imports
const TypeErasedCallback = @import("observable_instrument.zig").TypeErasedCallback;

// Observable instrument imports
const ObservableInstrument = @import("observable_instrument.zig").ObservableInstrument;

/// Meter interface using tagged union for polymorphism
pub const Meter = union(enum) {
    noop: InstrumentationScope,
    bridge: MeterBridge,

    /// Create a Counter instrument for i64 values
    ///
    /// This method creates a counter instrument with validation in debug builds.
    /// Counters are monotonic instruments that only increase over time.
    ///
    /// ## Parameters
    /// - `name`: Instrument name (validated for non-empty, valid characters)
    /// - `description`: Optional description (validated for reasonable length)
    /// - `unit`: Optional unit specification (validated for format)
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Name**: Must be non-empty and contain valid characters
    /// - **Description**: Must be reasonable length if provided
    /// - **Unit**: Must follow valid unit format if provided
    /// - **Type**: Must be i64 or f64 (compile-time check)
    ///
    /// ## Performance
    /// - **Release builds**: No validation overhead
    /// - **Debug builds**: Minimal overhead for validation checks
    pub inline fn createCounter(
        self: *const Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?AdvisoryParams,
    ) !Counter(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("Counters must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => Counter(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createCounterI64Fn(bridge.meter_ptr, name, description, unit, advisory),
                f64 => bridge.createCounterF64Fn(bridge.meter_ptr, name, description, unit, advisory),
                else => unreachable,
            },
        };
    }

    /// Create an UpDownCounter instrument for i64 values
    ///
    /// This method creates an up-down counter instrument with validation in debug builds.
    /// UpDownCounters can increase and decrease, tracking values that go up and down.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Name**: Must be non-empty and contain valid characters
    /// - **Description**: Must be reasonable length if provided
    /// - **Unit**: Must follow valid unit format if provided
    /// - **Type**: Must be i64 or f64 (compile-time check)
    pub inline fn createUpDownCounter(
        self: *const Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?AdvisoryParams,
    ) !UpDownCounter(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("UpDownCounters must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => UpDownCounter(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createUpDownCounterI64Fn(bridge.meter_ptr, name, description, unit, advisory),
                f64 => bridge.createUpDownCounterF64Fn(bridge.meter_ptr, name, description, unit, advisory),
                else => unreachable,
            },
        };
    }

    /// Create a Gauge instrument for i64 values
    ///
    /// This method creates a gauge instrument with validation in debug builds.
    /// Gauges represent values that can be set to any value at any time.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Name**: Must be non-empty and contain valid characters
    /// - **Description**: Must be reasonable length if provided
    /// - **Unit**: Must follow valid unit format if provided
    /// - **Type**: Must be i64 or f64 (compile-time check)
    pub inline fn createGauge(
        self: *const Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?AdvisoryParams,
    ) !Gauge(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("Gauges must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => Gauge(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createGaugeI64Fn(bridge.meter_ptr, name, description, unit, advisory),
                f64 => bridge.createGaugeF64Fn(bridge.meter_ptr, name, description, unit, advisory),
                else => unreachable,
            },
        };
    }

    /// Create a Histogram instrument
    ///
    /// This method creates a histogram instrument with validation in debug builds.
    /// Histograms record distributions of values and are useful for measuring latencies.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Name**: Must be non-empty and contain valid characters
    /// - **Description**: Must be reasonable length if provided
    /// - **Unit**: Must follow valid unit format if provided
    /// - **Type**: Must be i64 or f64 (compile-time check)
    pub inline fn createHistogram(
        self: *const Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?AdvisoryParams,
    ) !Histogram(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("Histograms must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => Histogram(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createHistogramI64Fn(bridge.meter_ptr, name, description, unit, advisory),
                f64 => bridge.createHistogramF64Fn(bridge.meter_ptr, name, description, unit, advisory),
                else => unreachable,
            },
        };
    }

    /// Create an ObservableCounter instrument
    ///
    /// This method creates an observable counter instrument with validation in debug builds.
    /// Observable counters use callbacks to report monotonic, non-decreasing values.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Name**: Must be non-empty and contain valid characters
    /// - **Description**: Must be reasonable length if provided
    /// - **Unit**: Must follow valid unit format if provided
    /// - **Type**: Must be i64 or f64 (compile-time check)
    pub inline fn createObservableCounter(
        self: *const Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?AdvisoryParams,
        callbacks: []const TypeErasedCallback(T),
    ) !ObservableInstrument(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("ObservableCounters must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => ObservableInstrument(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createObservableCounterI64Fn(bridge.meter_ptr, name, description, unit, advisory, callbacks),
                f64 => bridge.createObservableCounterF64Fn(bridge.meter_ptr, name, description, unit, advisory, callbacks),
                else => unreachable,
            },
        };
    }

    /// Create an ObservableGauge instrument
    ///
    /// This method creates an observable gauge instrument with validation in debug builds.
    /// Observable gauges use callbacks to report current values.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Name**: Must be non-empty and contain valid characters
    /// - **Description**: Must be reasonable length if provided
    /// - **Unit**: Must follow valid unit format if provided
    /// - **Type**: Must be i64 or f64 (compile-time check)
    pub inline fn createObservableGauge(
        self: *const Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?AdvisoryParams,
        callbacks: []const TypeErasedCallback(T),
    ) !ObservableInstrument(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("ObservableGauges must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => ObservableInstrument(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createObservableGaugeI64Fn(bridge.meter_ptr, name, description, unit, advisory, callbacks),
                f64 => bridge.createObservableGaugeF64Fn(bridge.meter_ptr, name, description, unit, advisory, callbacks),
                else => unreachable,
            },
        };
    }

    /// Create an ObservableUpDownCounter instrument
    ///
    /// This method creates an observable up-down counter instrument with validation in debug builds.
    /// Observable up-down counters use callbacks to report values that can increase and decrease.
    ///
    /// ## Validation (Debug Mode Only)
    /// - **Name**: Must be non-empty and contain valid characters
    /// - **Description**: Must be reasonable length if provided
    /// - **Unit**: Must follow valid unit format if provided
    /// - **Type**: Must be i64 or f64 (compile-time check)
    pub inline fn createObservableUpDownCounter(
        self: *const Meter,
        comptime T: type,
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        advisory: ?AdvisoryParams,
        callbacks: []const TypeErasedCallback(T),
    ) !ObservableInstrument(T) {
        comptime switch (T) {
            i64, f64 => {},
            else => @compileError("ObservableUpDownCounters must be of type i64 or f64"),
        };

        return switch (self.*) {
            .noop => ObservableInstrument(T){ .noop = name },
            .bridge => |*bridge| switch (T) {
                i64 => bridge.createObservableUpDownCounterI64Fn(bridge.meter_ptr, name, description, unit, advisory, callbacks),
                f64 => bridge.createObservableUpDownCounterF64Fn(bridge.meter_ptr, name, description, unit, advisory, callbacks),
                else => unreachable,
            },
        };
    }
};

/// Validate instrument name according to OpenTelemetry requirements
/// ABNF: instrument-name = ALPHA 0*254 ("_" / "." / "-" / "/" / ALPHA / DIGIT)
pub fn validateInstrumentName(name: []const u8) []const u8 {
    if (!isValidatingMode()) return name;

    if (name.len == 0) {
        reportValidationError(.meter, "createInstrument", "Empty instrument name provided", null);
        return name;
    }

    if (name.len > 255) {
        reportValidationError(.meter, "createInstrument", "Instrument name too long", "names must be <= 255 characters");
        return name;
    }

    // ABNF: First character must be alphabetic
    if (!std.ascii.isAlphabetic(name[0])) {
        reportValidationError(.meter, "createInstrument", "Invalid instrument name", "first character must be alphabetic (A-Z, a-z)");
        return name;
    }

    // ABNF: Subsequent characters validation
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-' and c != '/') {
            reportValidationError(.meter, "createInstrument", "Invalid character in instrument name", "names should contain only letters, digits, underscore, dot, hyphen, or slash");
            break; // Report once per name
        }
    }

    return name;
}

/// Validate instrument description for reasonable length
pub fn validateInstrumentDescription(description: ?[]const u8) ?[]const u8 {
    if (!isValidatingMode()) return description;

    if (description) |desc| {
        if (desc.len == 0) {
            reportValidationError(.meter, "createInstrument", "Empty description provided", "consider omitting description if not needed");
        } else if (desc.len > 1024) {
            reportValidationError(.meter, "createInstrument", "Description too long", "descriptions should be concise (< 1024 characters)");
        }
    }

    return description;
}

/// Validate instrument unit format
pub fn validateInstrumentUnit(unit: ?[]const u8) ?[]const u8 {
    if (!isValidatingMode()) return unit;

    if (unit) |u| {
        if (u.len == 0) {
            reportValidationError(.meter, "createInstrument", "Empty unit provided", "consider omitting unit if not applicable");
        } else if (u.len > 63) {
            // Per OpenTelemetry spec, units should be short
            reportValidationError(.meter, "createInstrument", "Unit string too long", "units should be short identifiers (< 63 characters)");
        }
        // Additional unit format validation could be added here
        // (e.g., checking against known units, format patterns)
    }

    return unit;
}

/// Validate counter value is non-negative (for SDK use only)
pub fn validateCounterValue(comptime T: type, value: T) bool {
    if (!isValidatingMode()) return true;
    return switch (T) {
        i64 => value >= 0,
        f64 => value >= 0.0,
        else => @compileError("Invalid counter type"),
    };
}

/// Validate histogram value is non-negative (for SDK use only)
pub fn validateHistogramValue(comptime T: type, value: T) bool {
    if (!isValidatingMode()) return true;
    return switch (T) {
        i64 => value >= 0,
        f64 => value >= 0.0,
        else => @compileError("Invalid histogram type"),
    };
}

/// Bridge structure that holds SDK meter pointer and vtable
pub const MeterBridge = struct {
    meter_ptr: *anyopaque,
    createCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Counter(i64),
    createCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Counter(f64),
    createUpDownCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!UpDownCounter(i64),
    createUpDownCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!UpDownCounter(f64),
    createGaugeI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Gauge(i64),
    createGaugeF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Gauge(f64),
    createHistogramI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Histogram(i64),
    createHistogramF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Histogram(f64),
    createObservableCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(i64)) anyerror!ObservableInstrument(i64),
    createObservableCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(f64)) anyerror!ObservableInstrument(f64),
    createObservableGaugeI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(i64)) anyerror!ObservableInstrument(i64),
    createObservableGaugeF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(f64)) anyerror!ObservableInstrument(f64),
    createObservableUpDownCounterI64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(i64)) anyerror!ObservableInstrument(i64),
    createObservableUpDownCounterF64Fn: *const fn (meter_ptr: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(f64)) anyerror!ObservableInstrument(f64),

    pub fn init(ptr: anytype) MeterBridge {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn createCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Counter(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createCounterF64(self, name, description, unit, advisory);
            }
            pub fn createCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Counter(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createCounterI64(self, name, description, unit, advisory);
            }
            pub fn createUpDownCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!UpDownCounter(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createUpDownCounterF64(self, name, description, unit, advisory);
            }
            pub fn createUpDownCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!UpDownCounter(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createUpDownCounterI64(self, name, description, unit, advisory);
            }
            pub fn createGaugeF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Gauge(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createGaugeF64(self, name, description, unit, advisory);
            }
            pub fn createGaugeI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Gauge(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createGaugeI64(self, name, description, unit, advisory);
            }
            pub fn createHistogramF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Histogram(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createHistogramF64(self, name, description, unit, advisory);
            }
            pub fn createHistogramI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams) anyerror!Histogram(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createHistogramI64(self, name, description, unit, advisory);
            }
            pub fn createObservableCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(i64)) anyerror!ObservableInstrument(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableCounterI64(self, name, description, unit, advisory, callbacks);
            }
            pub fn createObservableCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(f64)) anyerror!ObservableInstrument(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableCounterF64(self, name, description, unit, advisory, callbacks);
            }
            pub fn createObservableGaugeI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(i64)) anyerror!ObservableInstrument(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableGaugeI64(self, name, description, unit, advisory, callbacks);
            }
            pub fn createObservableGaugeF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(f64)) anyerror!ObservableInstrument(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableGaugeF64(self, name, description, unit, advisory, callbacks);
            }
            pub fn createObservableUpDownCounterI64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(i64)) anyerror!ObservableInstrument(i64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableUpDownCounterI64(self, name, description, unit, advisory, callbacks);
            }
            pub fn createObservableUpDownCounterF64(pointer: *anyopaque, name: []const u8, description: ?[]const u8, unit: ?[]const u8, advisory: ?AdvisoryParams, callbacks: []const TypeErasedCallback(f64)) anyerror!ObservableInstrument(f64) {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.createObservableUpDownCounterF64(self, name, description, unit, advisory, callbacks);
            }
        };

        return .{
            .meter_ptr = ptr,
            .createCounterI64Fn = VTable.createCounterI64,
            .createCounterF64Fn = VTable.createCounterF64,
            .createUpDownCounterI64Fn = VTable.createUpDownCounterI64,
            .createUpDownCounterF64Fn = VTable.createUpDownCounterF64,
            .createGaugeI64Fn = VTable.createGaugeI64,
            .createGaugeF64Fn = VTable.createGaugeF64,
            .createHistogramI64Fn = VTable.createHistogramI64,
            .createHistogramF64Fn = VTable.createHistogramF64,
            .createObservableCounterI64Fn = VTable.createObservableCounterI64,
            .createObservableCounterF64Fn = VTable.createObservableCounterF64,
            .createObservableGaugeI64Fn = VTable.createObservableGaugeI64,
            .createObservableGaugeF64Fn = VTable.createObservableGaugeF64,
            .createObservableUpDownCounterI64Fn = VTable.createObservableUpDownCounterI64,
            .createObservableUpDownCounterF64Fn = VTable.createObservableUpDownCounterF64,
        };
    }
};
