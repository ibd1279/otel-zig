//! OpenTelemetry Metrics Processor
//!
//! This module provides metric processors that collect measurements from instruments
//! and export them via metric exporters. Processors handle the timing and batching
//! of metric exports.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md#metricreader

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const BasicMeter = @import("meter.zig").Meter;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
};

/// Union type for metric values to avoid generic anytype parameters
pub const MetricValue = union(enum) {
    i64: i64,
    f64: f64,
};

/// Metric reader interface
pub const Reader = union(enum) {
    noop: void,
    bridge: BridgeReader,

    pub fn collect(self: *const Reader) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.collectFn(reader.reader_ptr),
        }
    }

    pub fn registerMeter(self: *const Reader, meter: *sdk.BasicMeter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.registerMeterFn(reader.reader_ptr, meter),
        }
    }

    pub fn unregisterMeter(self: *const Reader, meter: *sdk.BasicMeter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.unregisterMeterFn(reader.reader_ptr, meter),
        }
    }

    pub fn unregisterAllMeters(self: *const Reader) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.unregisterAllMetersFn(reader.reader_ptr),
        }
    }

    pub fn forceFlush(self: *const Reader, timeout_ms: ?u64) api.common.FlushResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |reader| reader.forceFlushFn(reader.reader_ptr, timeout_ms),
        };
    }

    pub fn shutdown(self: *const Reader, timeout_ms: ?u64) api.common.ProcessResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |reader| reader.shutdownFn(reader.reader_ptr, timeout_ms),
        };
    }

    /// Clean up reader resources
    pub fn deinit(self: *const Reader) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.deinitFn(reader.reader_ptr),
        }
    }

    /// Destroy reader memory
    pub fn destroy(self: *const Reader) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.destroyFn(reader.reader_ptr),
        }
    }

    pub fn setResource(self: *const Reader, resource: @import("../resource/resource.zig").Resource) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.setResourceFn(reader.reader_ptr, resource),
        }
    }

    /// Record a measurement from an instrument
    pub fn recordMeasurement(
        self: *const Reader,
        value: MetricValue,
        attributes: []const api.AttributeKeyValue,
        metadata: sdk.MetricMetadata,
        metadata_hash: u64,
    ) void {
        switch (self.*) {
            .noop => {},
            .bridge => |reader| reader.recordMeasurementFn(reader.reader_ptr, value, attributes, metadata, metadata_hash),
        }
    }
};

/// Interface for bridging to a more complex reader.
pub const BridgeReader = struct {
    reader_ptr: *anyopaque,
    collectFn: *const fn (reader_ptr: *anyopaque) void,
    forceFlushFn: *const fn (reader_ptr: *anyopaque, timeout_ms: ?u64) api.common.FlushResult,
    shutdownFn: *const fn (reader_ptr: *anyopaque, timeout_ms: ?u64) api.common.ProcessResult,
    deinitFn: *const fn (reader_ptr: *anyopaque) void,
    destroyFn: *const fn (reader_ptr: *anyopaque) void,
    registerMeterFn: *const fn (reader_ptr: *anyopaque, meter: *sdk.BasicMeter) void,
    unregisterMeterFn: *const fn (reader_ptr: *anyopaque, meter: *sdk.BasicMeter) void,
    unregisterAllMetersFn: *const fn (reader_ptr: *anyopaque) void,
    recordMeasurementFn: *const fn (reader_ptr: *anyopaque, value: MetricValue, attributes: []const api.AttributeKeyValue, metadata: sdk.MetricMetadata, metadata_hash: u64) void,
    setResourceFn: *const fn (reader_ptr: *anyopaque, resource: @import("../resource/resource.zig").Resource) void,

    pub fn init(ptr: anytype) BridgeReader {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn collect(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.collect(self);
            }
            pub fn forceFlush(pointer: *anyopaque, timeout_ms: ?u64) api.common.FlushResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.forceFlush(self, timeout_ms);
            }
            pub fn shutdown(pointer: *anyopaque, timeout_ms: ?u64) api.common.ProcessResult {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.shutdown(self, timeout_ms);
            }
            pub fn deinit(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self);
            }
            pub fn destroy(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.destroy(self);
            }
            pub fn registerMeter(pointer: *anyopaque, meter: *sdk.BasicMeter) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.registerMeter(self, meter);
            }
            pub fn unregisterMeter(pointer: *anyopaque, meter: *sdk.BasicMeter) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.unregisterMeter(self, meter);
            }
            pub fn unregisterAllMeters(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.unregisterAllMeters(self);
            }
            pub fn recordMeasurement(pointer: *anyopaque, value: MetricValue, attributes: []const api.AttributeKeyValue, metadata: sdk.MetricMetadata, metadata_hash: u64) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.recordMeasurement(self, value, attributes, metadata, metadata_hash);
            }
            pub fn setResource(pointer: *anyopaque, resource: @import("../resource/resource.zig").Resource) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.setResource(self, resource);
            }
        };

        return .{
            .reader_ptr = ptr,
            .collectFn = VTable.collect,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
            .registerMeterFn = VTable.registerMeter,
            .unregisterMeterFn = VTable.unregisterMeter,
            .unregisterAllMetersFn = VTable.unregisterAllMeters,
            .recordMeasurementFn = VTable.recordMeasurement,
            .setResourceFn = VTable.setResource,
        };
    }
};
