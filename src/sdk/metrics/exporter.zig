const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const MetricData = @import("data.zig").MetricData;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
};

/// Metric exporter interface
pub const MetricExporter = union(enum) {
    noop: void,
    bridge: BridgeMetricExporter,

    /// Export a batch of metrics
    ///
    /// The caller is required to manage `metrics`. The exporter must be finished with
    /// the memory when this function returns. That includes making deep copies if
    /// necessary for buffering.
    pub fn exportMetrics(self: *const MetricExporter, metrics: []const sdk.MetricData) api.common.ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.exportFn(exporter, metrics),
        };
    }

    /// Force flush any buffered data
    pub fn forceFlush(self: *const MetricExporter, timeout_ms: ?u64) api.common.ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.forceFlushFn(exporter, timeout_ms),
        };
    }

    /// Shutdown the exporter
    pub fn shutdown(self: *const MetricExporter, timeout_ms: ?u64) api.common.ExportResult {
        return switch (self.*) {
            .noop => .success,
            .bridge => |exporter| exporter.shutdownFn(exporter, timeout_ms),
        };
    }

    /// Clean up exporter resources
    pub fn deinit(self: *const MetricExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.deinitFn(exporter),
        }
    }

    /// Destroy exporter memory
    pub fn destroy(self: *const MetricExporter) void {
        switch (self.*) {
            .noop => {},
            .bridge => |exporter| exporter.destroyFn(exporter.exporter_ptr),
        }
    }
};

pub const BridgeMetricExporter = struct {
    exporter_ptr: *anyopaque,
    exportFn: *const fn (ptr: BridgeMetricExporter, metrics: []const sdk.MetricData) api.common.ExportResult,
    forceFlushFn: *const fn (ptr: BridgeMetricExporter, timeout_ms: ?u64) api.common.ExportResult,
    shutdownFn: *const fn (ptr: BridgeMetricExporter, timeout_ms: ?u64) api.common.ExportResult,
    deinitFn: *const fn (self: BridgeMetricExporter) void,
    destroyFn: *const fn (ptr: *anyopaque) void,

    pub fn init(ptr: anytype) BridgeMetricExporter {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const VTable = struct {
            pub fn exportMetrics(self: BridgeMetricExporter, metrics: []const sdk.MetricData) api.common.ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.exportMetrics(actual_self, metrics);
            }
            pub fn forceFlush(self: BridgeMetricExporter, timeout_ms: ?u64) api.common.ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.forceFlush(actual_self, timeout_ms);
            }
            pub fn shutdown(self: BridgeMetricExporter, timeout_ms: ?u64) api.common.ExportResult {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.shutdown(actual_self, timeout_ms);
            }
            pub fn deinit(self: BridgeMetricExporter) void {
                const actual_self: T = @ptrCast(@alignCast(self.exporter_ptr));
                return ptr_info.pointer.child.deinit(actual_self);
            }
            pub fn destroy(pointer: *anyopaque) void {
                const actual_self: T = @ptrCast(@alignCast(pointer));
                actual_self.destroy();
            }
        };

        return .{
            .exporter_ptr = ptr,
            .exportFn = VTable.exportMetrics,
            .forceFlushFn = VTable.forceFlush,
            .shutdownFn = VTable.shutdown,
            .deinitFn = VTable.deinit,
            .destroyFn = VTable.destroy,
        };
    }
};

/// Mock metric exporter for testing purposes
/// Captures exported metrics for verification without external dependencies.
pub const MockMetricExporter = struct {
    pub const PipelineStep = @import("../common/pipeline.zig").PipelineStepInstructions(
        Self,
        MetricExporter,
        void,
        metricExporter,
        _init,
        @import("../common/pipeline.zig").PipelineDeinitConnection,
    );
    const Self = @This();

    pub fn _init(self: *Self, _: void, allocator: std.mem.Allocator) !void {
        self.* = init(allocator);
    }

    allocator: std.mem.Allocator,
    export_count: std.atomic.Value(u64),
    exported_metrics: std.ArrayList(sdk.MetricData),
    export_result: api.common.ExportResult,
    flush_result: api.common.ExportResult,
    shutdown_result: api.common.ExportResult,
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator) MockMetricExporter {
        return .{
            .allocator = allocator,
            .exported_metrics = .empty,
            .export_count = .init(0),
            .export_result = .success,
            .flush_result = .success,
            .shutdown_result = .success,
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *MockMetricExporter) void {
        for (self.exported_metrics.items) |data| {
            for (data.data_points) |point| {
                api.AttributeKeyValue.deinitOwnedSlice(self.allocator, point.attributes);
            }
            self.allocator.free(data.name);
            if (data.description) |d| self.allocator.free(d);
            if (data.unit) |d| self.allocator.free(d);
            self.allocator.free(data.data_points);
        }
        self.exported_metrics.deinit(self.allocator);
    }

    pub fn destroy(self: *MockMetricExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportMetrics(self: *MockMetricExporter, metrics: []const sdk.MetricData) api.common.ExportResult {
        _ = self.export_count.fetchAdd(1, .acq_rel);

        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        for (metrics) |metric| {
            self.internalExportMetric(metric) catch return .failure;
        }
        return self.export_result;
    }

    fn internalExportMetric(self: *MockMetricExporter, metric_data: sdk.MetricData) !void {
        // Deep copy the metric since the exporter needs to own the data
        var data_points = std.ArrayList(sdk.MetricDataPoint).empty;
        errdefer {
            for (data_points.items) |data_point| api.AttributeKeyValue.deinitOwnedSlice(self.allocator, data_point.attributes);
            data_points.deinit(self.allocator);
        }
        for (metric_data.data_points) |point| {
            var new_point = point;
            new_point.attributes = try api.AttributeKeyValue.initOwnedSlice(self.allocator, point.attributes);
            errdefer api.AttributeKeyValue.deinitOwnedSlice(self.allocator, new_point.attributes);
            try data_points.append(self.allocator, new_point);
        }
        const points = try data_points.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(points);

        const name = try self.allocator.dupe(u8, metric_data.name);
        errdefer self.allocator.free(name);
        const description = if (metric_data.description) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (description) |v| self.allocator.free(v);
        const unit = if (metric_data.unit) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (unit) |v| self.allocator.free(v);

        try self.exported_metrics.append(self.allocator, .{
            .name = name,
            .description = description,
            .unit = unit,
            .type = metric_data.type,
            .data_points = points,
            .scope = metric_data.scope,
            .resource = metric_data.resource,
        });
    }

    pub fn forceFlush(self: *MockMetricExporter, timeout_ms: ?u64) api.common.ExportResult {
        _ = timeout_ms;
        return self.flush_result;
    }

    pub fn shutdown(self: *MockMetricExporter, timeout_ms: ?u64) api.common.ExportResult {
        _ = timeout_ms;
        return self.shutdown_result;
    }

    pub fn metricExporter(self: *MockMetricExporter) MetricExporter {
        return MetricExporter{ .bridge = BridgeMetricExporter.init(self) };
    }

    // Test helpers
    pub fn clearMetrics(self: *MockMetricExporter) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        self.exported_metrics.clearRetainingCapacity();
    }

    pub fn metricCount(self: *MockMetricExporter) usize {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        return self.exported_metrics.items.len;
    }

    pub fn exportCount(self: *MockMetricExporter) u64 {
        return self.export_count.load(.monotonic);
    }

    pub fn clearExportCount(self: *MockMetricExporter) void {
        self.export_count.store(0, .release);
    }

    pub fn getMetric(self: *MockMetricExporter, index: usize) ?sdk.MetricData {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (index >= self.exported_metrics.items.len) return null;
        return self.exported_metrics.items[index];
    }

    /// Get metrics matching the provided name, writing them into the provided buffer.
    /// Returns a slice of the buffer containing the matching metrics.
    pub fn getMetricsNamed(self: *MockMetricExporter, buffer: []sdk.MetricData, name: []const u8) []sdk.MetricData {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        var count: usize = 0;
        for (self.exported_metrics.items) |metric| {
            if (count >= buffer.len) break;
            if (std.mem.eql(u8, metric.name, name)) {
                buffer[count] = metric;
                count += 1;
            }
        }
        return buffer[0..count];
    }
};
