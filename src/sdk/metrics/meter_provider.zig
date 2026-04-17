//! OpenTelemetry SDK Meter Provider Implementation
//!
//! This module provides the concrete implementation of the MeterProvider interface
//! for the SDK. MeterProvider manages meters and their lifecycle.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
    const common = struct {
        const InstrumentationScopeMapContext = @import("../common/scope_context.zig").InstrumentationScopeMapContext;
        const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
        const Timeout = @import("../common/timeout.zig");
    };
    const metrics = struct {
        const AggregationType = @import("aggregations.zig").AggregationType;
        const InstrumentType = @import("metadata.zig").InstrumentType;
        const Meter = @import("meter.zig").Meter;
        const Reader = @import("reader.zig").Reader;
        const View = @import("view.zig");
    };
};

/// Basic meter provider with caching and configuration
pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: sdk.Resource,
    cache: std.HashMapUnmanaged(api.InstrumentationScope, *sdk.metrics.Meter, sdk.common.InstrumentationScopeMapContext, 80),
    readers: std.ArrayListUnmanaged(sdk.metrics.Reader),
    views: std.ArrayListUnmanaged(sdk.metrics.View),
    mutex: std.Io.Mutex,
    is_shutdown: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        resource: sdk.Resource,
    ) MeterProvider {
        return .{
            .allocator = allocator,
            .io = io,
            .resource = resource,
            .cache = .empty,
            .readers = .empty,
            .views = .empty,
            .mutex = std.Io.Mutex.init,
            .is_shutdown = .init(false),
        };
    }

    pub fn deinit(self: *MeterProvider) void {
        // make sure we have shutdown before freeing resources. This
        // involves the mutex, so doing it outside of the Mutex.
        _ = self.shutdown(null);

        // readers reference the meters for invoking the async instruments
        // clean those up. Probably involves a mutex on the reader, so
        // doing it outside of the Mutex
        for (self.readers.items) |*reader| reader.unregisterAllMeters();

        // Clean up the local lists.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // Clean up the meters.
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                kv.key_ptr.deinitOwned(self.allocator);
                kv.value_ptr.*.deinit();
                self.allocator.destroy(kv.value_ptr.*);
            }
            self.cache.deinit(self.allocator);

            // Clean up the readers.
            for (self.readers.items) |reader| {
                reader.deinit();
                reader.destroy();
            }
            self.readers.deinit(self.allocator);
        }

        // Clean up the owned structures. With the meters gone, these can be cleaned up.
        self.views.deinit(self.allocator);
        self.resource.deinitOwned(self.allocator);
    }

    /// Destroys the provider instance (assumes deinit() was already called)
    pub fn destroy(self: *MeterProvider) void {
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *MeterProvider, timeout_ms: ?u64) api.common.ProcessResult {
        if (self.is_shutdown.load(.monotonic)) return .success;

        const timeout = sdk.common.Timeout.init(timeout_ms);

        // The mutex block is distinct because the mutex must be released before
        // forceFlush can be called.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // Flag each meter as shutdown to stop collection and instrument creation
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                if (timeout.isExpired()) return .timeout;
                kv.value_ptr.*.shutdown();
            }
        }

        const result = self.forceFlush(timeout.remaining() catch return .timeout).asProcessResult();
        if (result.isSuccess()) self.is_shutdown.store(true, .monotonic);
        return result;
    }

    /// Interface defined method to force the attached processor to flush.
    pub fn forceFlush(self: *MeterProvider, timeout_ms: ?u64) api.common.FlushResult {
        // Shutdown providers can still force flush. No shutdown check.

        const timeout = sdk.common.Timeout.init(timeout_ms);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.readers.items) |*reader| {
            reader.collect();
            const flush_result = reader.forceFlush(timeout.remaining() catch return .timeout);
            switch (flush_result) {
                .success => {},
                else => return flush_result,
            }
        }
        return .success;
    }

    /// Interface defined method to get a meter.
    ///
    /// The provided scope is copied internally.
    pub fn getMeterWithScope(self: *MeterProvider, scope: api.InstrumentationScope) !api.metrics.Meter {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Check cache first
        if (self.cache.get(scope)) |meter| {
            return meter.meter();
        }

        // Create a locally owned Scope.
        const owned_scope = try api.InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK meter
        const sdk_meter = try self.allocator.create(sdk.metrics.Meter);
        errdefer self.allocator.destroy(sdk_meter);

        sdk_meter.* = try sdk.metrics.Meter.init(self, owned_scope);

        // Register the meter with the processor for collection
        //
        // Iterating over processors should be thread safe as they can
        // only be mutated at start-up / single threaded.
        for (self.readers.items) |*reader| reader.registerMeter(sdk_meter);

        try self.cache.put(self.allocator, owned_scope, sdk_meter);

        return sdk_meter.meter();
    }

    /// Add a view to this provider
    /// Views are immutable after setupGlobalProvider is called
    pub fn addView(self: *MeterProvider, view: sdk.metrics.View) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.views.append(self.allocator, view);
    }

    /// Apply all registered views to an instrument, returning view applications
    /// If no views match, returns a single default view application
    pub fn applyViews(
        self: *MeterProvider,
        instrument_name: []const u8,
        instrument_type: sdk.metrics.InstrumentType,
        instrument_unit: []const u8,
        instrument_description: ?[]const u8,
        meter_name: []const u8,
        meter_version: ?[]const u8,
        meter_schema_url: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]sdk.metrics.View.Application {
        _ = instrument_description; // TODO: Use in view validation
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var applications = std.ArrayList(sdk.metrics.View.Application).empty;
        defer applications.deinit(allocator);

        for (self.views.items) |view| {
            if (view.instrument_selector.matches(
                instrument_name,
                instrument_type,
                instrument_unit,
                meter_name,
                meter_version,
                meter_schema_url,
            )) {
                // Validate aggregation compatibility
                if (view.aggregation_override) |override_type| {
                    if (!isAggregationCompatible(instrument_type, override_type)) {
                        api.common.reportValidationError(.meter, "applyViews", "Incompatible aggregation type for instrument", null);
                        continue; // Skip this view
                    }
                }

                const app = sdk.metrics.View.Application{
                    .view = view,
                };
                try applications.append(allocator, app);
            }
        }

        // If no views matched, add default view
        if (applications.items.len == 0) {
            try applications.append(allocator, .{ .view = .default });
        }

        return try applications.toOwnedSlice(allocator);
    }

    /// Check if an aggregation type is compatible with an instrument type
    fn isAggregationCompatible(instrument_type: sdk.metrics.InstrumentType, aggregation_type: sdk.metrics.AggregationType) bool {
        return switch (instrument_type) {
            .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => switch (aggregation_type) {
                .sum, .drop => true,
                else => false,
            },
            .Gauge, .ObservableGauge => switch (aggregation_type) {
                .last_value, .drop => true,
                else => false,
            },
            .Histogram => switch (aggregation_type) {
                .histogram, .sum, .drop => true, // Histograms can be aggregated as sums
                else => false,
            },
        };
    }

    /// Attach a reader to this provider.
    ///
    /// This method is not thread-safe and should only be called during initialization.
    pub fn registerReader(self: *MeterProvider, reader: sdk.metrics.Reader) !void {
        reader.setResource(self.resource);
        try self.readers.append(self.allocator, reader);
    }

    /// Convert the provider into an API interface.
    pub fn meterProvider(self: *MeterProvider) api.metrics.MeterProvider {
        return api.metrics.MeterProvider{ .bridge = api.metrics.MeterProviderBridge.init(self) };
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *MeterProvider) sdk.common.PipelineBuilder(*MeterProvider) {
        return .init(self);
    }
};
