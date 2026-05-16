//! OpenTelemetry Observable Instrument SDK Implementation
//!
//! This module provides the concrete SDK implementation for observable/async instruments.
//! It includes callback management, metric collection, and performance monitoring.

const std = @import("std");
const api = @import("otel-api");

fn nanoTimestamp(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(ts.nanoseconds);
}

const sdk = struct {
    const AggregationTemporality = @import("aggregations.zig").AggregationTemporality;
    const InstrumentType = @import("metadata.zig").InstrumentType;
    const Meter = @import("meter.zig").Meter;
    const MetricData = @import("data.zig").MetricData;
    const MetricDataPoint = @import("data.zig").MetricDataPoint;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("data.zig").MetricValue;
    const Reader = @import("reader.zig").Reader;
    const Resource = @import("../resource/resource.zig").Resource;
    const View = @import("view.zig");
};

/// Wrapper for the different Observable types.
///
/// The spec says that observables all behave the same way, as far as the
/// callback is concerned : the call back should return the current absolute
/// value, not a delta. The SDK has the responsibilty of creating the right
/// temporality. In our implementation that is delegated to the reader stored
/// aggregations, not to the instrument.
pub fn Observable(comptime T: type) type {
    comptime switch (T) {
        i64, f64 => {},
        else => @compileError("ObservableInstrument must be of type i64 or f64"),
    };

    return struct {
        const Self = @This();

        /// Entry for a registered callback
        const CallbackEntry = struct {
            callback: api.metrics.TypeErasedCallback(T),
            id: u64,
        };

        /// Instrument metadata
        name: []const u8,
        description: ?[]const u8,
        unit: ?[]const u8,
        instrument_type: sdk.InstrumentType,
        meter: *sdk.Meter,
        metadata_hash: u64,

        /// Callback management
        callbacks: std.ArrayList(CallbackEntry),
        next_callback_id: u64,

        /// Configuration and state
        mutex: std.atomic.Mutex,
        config: AsyncInstrumentConfig,

        // Internal metrics instruments (if measure_callbacks is true)
        callback_duration_histogram: api.metrics.Histogram(f64),
        callback_executions_counter: api.metrics.Counter(i64),
        callback_errors_counter: api.metrics.Counter(i64),

        /// View support
        views: []const sdk.View.Application,

        /// Advisory parameters (Stable: ExplicitBucketBoundaries, Development: Attributes)
        advisory_params: ?api.metrics.AdvisoryParams,

        /// Initialize the observable counter
        pub fn init(
            name: []const u8,
            description: ?[]const u8,
            unit: ?[]const u8,
            instrument_type: sdk.InstrumentType,
            parent_meter: *sdk.Meter,
            config: AsyncInstrumentConfig,
            advisory_params: ?api.metrics.AdvisoryParams,
        ) !Self {
            // Precompute the hash values that don't change per datapoint.
            const metadata_hash = sdk.MetricMetadata.computeHash(
                name,
                unit orelse "",
                instrument_type,
                &parent_meter.scope,
            );

            // Get the views that apply to this instrument.
            const view_applications = try parent_meter.provider.applyViews(
                name,
                instrument_type,
                unit orelse "",
                description,
                parent_meter.scope.name,
                parent_meter.scope.version,
                parent_meter.scope.schema_url,
                parent_meter.provider.allocator,
            );

            // Clone advisory params to ensure instrument owns the memory
            const owned_advisory_params = if (advisory_params) |params| blk: {
                var owned = params;
                // Clone explicit_bucket_boundaries if present (Stable)
                if (params.explicit_bucket_boundaries) |boundaries| {
                    owned.explicit_bucket_boundaries = try parent_meter.provider.allocator.dupe(f64, boundaries);
                }
                // Clone attributes if present (Development)
                if (params.attributes) |attrs| {
                    const owned_attrs = try parent_meter.provider.allocator.alloc([]const u8, attrs.len);
                    for (attrs, 0..) |attr, i| {
                        owned_attrs[i] = try parent_meter.provider.allocator.dupe(u8, attr);
                    }
                    owned.attributes = owned_attrs;
                }
                break :blk owned;
            } else null;

            // Create internal metrics instruments if configured
            var callback_duration_histogram = api.metrics.Histogram(f64){ .noop = "otel.sdk.metrics.async.callback.duration" };
            var callback_executions_counter = api.metrics.Counter(i64){ .noop = "otel.sdk.metrics.async.callback.executions" };
            var callback_errors_counter = api.metrics.Counter(i64){ .noop = "otel.sdk.metrics.async.callback.errors" };

            if (config.measure_callbacks) {
                // Get global meter provider and create internal meter
                const global_provider = api.getGlobalMeterProvider();
                const internal_scope = api.InstrumentationScope{
                    .name = "otel.sdk.metrics.async",
                    .version = "1.0.0", // TODO: Use actual SDK version
                };
                var internal_meter = global_provider.getMeterWithScope(internal_scope);

                // Create histogram for callback duration
                callback_duration_histogram = try internal_meter.createHistogram(
                    f64,
                    "otel.sdk.metrics.async.callback.duration",
                    "Duration of async instrument callback executions",
                    "us",
                    null,
                );

                // Create counter for executions
                callback_executions_counter = try internal_meter.createCounter(
                    i64,
                    "otel.sdk.metrics.async.callback.executions",
                    "Total number of async instrument callback executions",
                    "{execution}",
                    null,
                );

                // Create counter for errors
                callback_errors_counter = try internal_meter.createCounter(
                    i64,
                    "otel.sdk.metrics.async.callback.errors",
                    "Total number of async instrument callback errors",
                    "{error}",
                    null,
                );
            }

            return .{
                .name = name,
                .description = description,
                .unit = unit,
                .instrument_type = instrument_type,
                .meter = parent_meter,
                .metadata_hash = metadata_hash,
                .callbacks = .empty,
                .next_callback_id = 1,
                .mutex = .unlocked,
                .config = config,
                .callback_duration_histogram = callback_duration_histogram,
                .callback_executions_counter = callback_executions_counter,
                .callback_errors_counter = callback_errors_counter,
                .views = view_applications,
                .advisory_params = owned_advisory_params,
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self, _: std.mem.Allocator) void {
            while (!self.mutex.tryLock()) {}
            defer self.mutex.unlock();

            // Free owned advisory params
            if (self.advisory_params) |params| {
                if (params.explicit_bucket_boundaries) |boundaries| {
                    self.meter.provider.allocator.free(boundaries);
                }
                if (params.attributes) |attrs| {
                    for (attrs) |attr| {
                        self.meter.provider.allocator.free(attr);
                    }
                    self.meter.provider.allocator.free(attrs);
                }
            }

            self.callbacks.deinit(self.meter.provider.allocator);
            self.meter.provider.allocator.free(self.views);
        }

        /// Get the name of this instrument
        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }

        /// Check if this instrument is enabled
        pub fn enabled(self: *const Self) bool {
            _ = self;
            return true; // SDK instruments are always enabled
        }

        /// Register a callback
        pub fn registerCallback(self: *Self, callback: api.metrics.TypeErasedCallback(T)) api.metrics.CallbackHandle {
            while (!self.mutex.tryLock()) {}
            defer self.mutex.unlock();

            const callback_id = self.next_callback_id;

            const entry = CallbackEntry{
                .callback = callback,
                .id = callback_id,
            };

            self.callbacks.append(self.meter.provider.allocator, entry) catch {
                // Return noop handle on allocation failure
                return .noop;
            };

            self.next_callback_id += 1;
            return .init(self, unregisterCallback, callback_id);
        }

        /// Unregister a callback (internal method)
        fn unregisterCallback(instrument_ptr: *anyopaque, callback_id: u64) void {
            const self: *Self = @ptrCast(@alignCast(instrument_ptr));

            while (!self.mutex.tryLock()) {}
            defer self.mutex.unlock();

            for (self.callbacks.items, 0..) |entry, i| {
                if (entry.id == callback_id) {
                    _ = self.callbacks.swapRemove(i);
                    break;
                }
            }
        }

        /// Trigger callbacks and record measurements.
        ///
        /// `allocator` is expected to be the readers allocator, to reduce copies.
        /// `points` is the readers export queue, to avoid copies.
        /// `reader` is the specific reader that triggered this observation.
        pub fn triggerObserve(self: *Self, allocator: std.mem.Allocator, reader: sdk.Reader) void {
            var buffer = std.ArrayList(api.metrics.ObservableResult(T).Measurement).empty;
            defer buffer.deinit(allocator);

            // lock for iteration over the callbacks.
            {
                while (!self.mutex.tryLock()) {}
                defer self.mutex.unlock();

                for (self.callbacks.items) |*entry| {
                    // Execute callback and collect measurements
                    const measurements = self.executeCallback(allocator, entry) catch |err| {
                        const error_message = switch (err) {
                            error.OutOfMemory => "Out of memory during callback execution",
                        };

                        // Record error using OTel instruments
                        if (self.config.measure_callbacks) {
                            const attributes = &[_]api.common.AttributeKeyValue{
                                .{ .key = "otel.instrument.name", .value = .{ .string = self.name } },
                                .{ .key = "otel.instrument.type", .value = .{ .string = @tagName(self.instrument_type) } },
                                .{ .key = "otel.callback.id", .value = .{ .int = @intCast(entry.id) } },
                            };
                            const ctx = &[_]api.ContextKeyValue{};
                            self.callback_errors_counter.add(ctx, 1, attributes);
                        }

                        switch (self.config.error_policy) {
                            .fail_fast => break,
                            .log_continue => {
                                api.common.reportError(.{
                                    .component = .meter,
                                    .context = null,
                                    .error_type = .internal,
                                    .message = error_message,
                                    .operation = "observable callback execution",
                                    .source_error = err,
                                });
                                continue;
                            },
                            .silent_ignore => continue,
                        }
                    };
                    defer allocator.free(measurements);

                    // buffer the measurements we did get.
                    if (measurements.len > 0) {
                        buffer.appendSlice(allocator, measurements) catch |err| {
                            switch (self.config.error_policy) {
                                .fail_fast => break,
                                .log_continue => {
                                    api.common.reportError(.{
                                        .component = .meter,
                                        .context = null,
                                        .error_type = .internal,
                                        .message = "Out of memory during callback aggregation.",
                                        .operation = "observable callback collection",
                                        .source_error = err,
                                    });
                                    continue;
                                },
                                .silent_ignore => continue,
                            }
                        };
                    }
                }
            }

            // Convert measurements to data points
            for (buffer.items) |measurement| {
                // Process each view application
                for (self.views) |view| {
                    // Skip drop aggregations
                    if (view.drops()) continue;

                    // Transform attributes according to view
                    const attrs = view.transformAttributes(measurement.attributes, allocator) catch |e| blk: {
                        api.common.reportErrorWithAllocator(.{
                            .component = .meter,
                            .context = null,
                            .error_type = .internal,
                            .message = "Unable to transform attributes with view",
                            .operation = "StandardCounter.addI64()",
                            .source_error = e,
                        }, allocator);
                        break :blk measurement.attributes; // On error, use original attributes
                    };

                    const metadata = sdk.MetricMetadata{
                        .name = view.getName(self.name),
                        .description = view.getDescription(self.description) orelse "",
                        .unit = self.unit orelse "", // Unit not transformable per spec
                        .instrument_type = self.instrument_type,
                        .instrumentation_scope = self.meter.scope,
                        .histogram_boundaries = if (self.advisory_params) |adv| adv.explicit_bucket_boundaries else null,
                    };

                    // When a view renames the metric stream, include the new name in the
                    // aggregation key so two views on the same instrument with different
                    // output names produce independent aggregation slots.
                    const view_hash = if (view.view.name != null)
                        sdk.MetricMetadata.computeHash(
                            metadata.name,
                            metadata.unit,
                            metadata.instrument_type,
                            &metadata.instrumentation_scope,
                        )
                    else
                        self.metadata_hash;

                    reader.recordMeasurement(
                        switch (T) {
                            i64 => .{ .i64 = measurement.value },
                            f64 => .{ .f64 = measurement.value },
                            else => unreachable,
                        },
                        attrs,
                        metadata,
                        view_hash,
                    );
                }
            }
        }

        /// Execute a single callback with proper error handling and timing
        fn executeCallback(self: *Self, allocator: std.mem.Allocator, entry: *CallbackEntry) ![]api.metrics.ObservableResult(T).Measurement {
            const ctx = &[_]api.ContextKeyValue{};
            const start_time = nanoTimestamp(self.meter.provider.io);

            var result = api.metrics.ObservableResult(T).empty;
            defer result.deinit(allocator);

            // Execute the callback - callbacks are void functions, so we detect errors by observing behavior
            switch (entry.callback) {
                .state => |cb| cb.callback_fn(allocator, &result, cb.state),
                .stateless => |cbFn| cbFn(allocator, &result),
            }

            // Record timing if enabled
            if (self.config.measure_callbacks) {
                const end_time = nanoTimestamp(self.meter.provider.io);
                const execution_time = @as(u64, @intCast(end_time - start_time));

                // Record execution metrics using OTel instruments
                const attributes = &[_]api.common.AttributeKeyValue{
                    .{ .key = "otel.instrument.name", .value = .{ .string = self.name } },
                    .{ .key = "otel.instrument.type", .value = .{ .string = @tagName(self.instrument_type) } },
                    .{ .key = "otel.callback.id", .value = .{ .int = @intCast(entry.id) } },
                };

                // Record execution time in microseconds
                const duration_us = @as(f64, @floatFromInt(execution_time)) / 1000.0;
                self.callback_duration_histogram.record(ctx, duration_us, attributes);

                // Record execution count
                self.callback_executions_counter.add(ctx, 1, attributes);
            }

            // Warn if no measurements were produced and policy requires it
            if (self.config.warn_on_no_measurements and result.measurements.items.len == 0) {
                const warn_msg = "Callback produced no measurements";

                // Record error using OTel instruments
                if (self.config.measure_callbacks) {
                    const attributes = &[_]api.common.AttributeKeyValue{
                        .{ .key = "otel.instrument.name", .value = .{ .string = self.name } },
                        .{ .key = "otel.instrument.type", .value = .{ .string = @tagName(self.instrument_type) } },
                        .{ .key = "otel.callback.id", .value = .{ .int = @intCast(entry.id) } },
                    };
                    self.callback_errors_counter.add(ctx, 1, attributes);
                }
                api.common.reportCallbackError(.meter, "executeCallback", warn_msg, self.name);
            }

            return result.measurements.toOwnedSlice(allocator);
        }

        /// Create MetricData from collected measurements
        pub fn createMetricData(self: *Self, allocator: std.mem.Allocator, scope: api.common.InstrumentationScope, resource: sdk.Resource) !sdk.MetricData {
            const data_points = try self.collect(allocator);

            return .{
                .name = self.name,
                .description = self.description,
                .unit = self.unit,
                .type = .sum,
                .data_points = data_points,
                .scope = scope,
                .resource = resource,
            };
        }

        /// Destroy the instrument
        pub fn destroy(self: *Self) void {
            self.allocator.destroy(self);
        }
    };
}

/// Error handling policy for callback execution
pub const CallbackErrorPolicy = enum {
    /// Stop processing on first callback error
    fail_fast,
    /// Log errors and continue with other callbacks
    log_continue,
    /// Silently ignore errors and continue
    silent_ignore,
};

/// Configuration for async instrument behavior
pub const AsyncInstrumentConfig = struct {
    /// Policy for handling callback errors
    error_policy: CallbackErrorPolicy,

    /// Maximum number of measurements allowed per callback
    /// null means no limit
    max_measurements_per_callback: ?usize,

    /// Whether to warn when callbacks produce no measurements
    warn_on_no_measurements: bool,

    /// Whether to measure callback performance using OTel instruments
    measure_callbacks: bool,

    /// Default config used
    pub const default: AsyncInstrumentConfig = .{
        .error_policy = .log_continue,
        .max_measurements_per_callback = null,
        .measure_callbacks = true,
        .warn_on_no_measurements = true,
    };

    pub const strict: AsyncInstrumentConfig = .{
        .error_policy = .fail_fast,
        .max_measurements_per_callback = 10,
        .measure_callbacks = true,
        .warn_on_no_measurements = true,
    };

    /// Default config for up-down counters
    pub const production: AsyncInstrumentConfig = .{
        .error_policy = .silent_ignore,
        .max_measurements_per_callback = 100,
        .measure_callbacks = false,
        .warn_on_no_measurements = false,
    };
};
