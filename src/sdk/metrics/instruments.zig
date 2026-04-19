//! OpenTelemetry Basic Meter Provider SDK Implementation
//!
//! This module provides the basic concrete implementation of MeterProvider for the SDK.
//! It manages meter lifecycle, caching, and configuration.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Meter = @import("meter.zig").Meter;
    const MetricMetadata = @import("metadata.zig").MetricMetadata;
    const MetricValue = @import("reader.zig").MetricValue;
    const aggregations = @import("aggregations.zig");
    const View = @import("view.zig");
};

const BaseType = enum {
    float,
    int,
};

fn Instrument(comptime inst_type: api.metrics.InstrumentType, comptime base_type: BaseType) type {
    switch (inst_type) {
        .ObservableCounter, .ObservableGauge, .ObservableUpDownCounter => @compileError("Attempt to create a Non-Observable Instrument of Obsevable type."),
        else => {},
    }
    const ValueType = switch (base_type) {
        .float => f64,
        .int => i64,
    };

    return switch (inst_type) {
        .Counter, .UpDownCounter => blk: {
            break :blk struct {
                const Self = @This();
                name: []const u8,
                description: ?[]const u8,
                unit: ?[]const u8,
                meter: *sdk.Meter,
                metadata_hash: u64,
                views: []sdk.View.Application,
                advisory_params: ?api.metrics.AdvisoryParams,

                pub fn init(
                    name: []const u8,
                    description: ?[]const u8,
                    unit: ?[]const u8,
                    parent_meter: *sdk.Meter,
                    advisory_params: ?api.metrics.AdvisoryParams,
                ) !Self {
                    // Precompute the hash values that don't change per datapoint.
                    const metadata_hash = sdk.MetricMetadata.computeHash(
                        name,
                        unit orelse "",
                        inst_type,
                        &parent_meter.scope,
                    );

                    // Get the views that apply to this instrument.
                    const view_applications = try parent_meter.provider.applyViews(
                        name,
                        inst_type,
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

                    return .{
                        .name = name,
                        .description = description,
                        .unit = unit,
                        .meter = parent_meter,
                        .metadata_hash = metadata_hash,
                        .views = view_applications,
                        .advisory_params = owned_advisory_params,
                    };
                }

                pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                    // Free owned advisory params
                    if (self.advisory_params) |params| {
                        if (params.explicit_bucket_boundaries) |boundaries| {
                            allocator.free(boundaries);
                        }
                        if (params.attributes) |attrs| {
                            for (attrs) |attr| {
                                allocator.free(attr);
                            }
                            allocator.free(attrs);
                        }
                    }
                    allocator.free(self.views);
                }

                pub fn getName(self: *const Self) []const u8 {
                    return self.name;
                }

                pub inline fn add(self: *const Self, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void {
                    if (inst_type == .Counter) {
                        if (!api.metrics.validateCounterValue(ValueType, value)) {
                            api.common.reportValidationError(.meter, "Counter.add", "Negative value provided", "counter values must be non-negative");
                            return; // Return early in validation mode
                        }
                    }
                    _ = ctx;

                    // Create an arena, so we don't have to keep track of which slices are
                    // allocated here, and which are unowned.
                    var arena = std.heap.ArenaAllocator.init(self.meter.provider.allocator);
                    defer arena.deinit();
                    const allocator = arena.allocator();

                    // Process each view application
                    for (self.views) |view| {
                        // Skip drop aggregations
                        if (view.drops()) continue;

                        // Transform attributes according to view, with advisory params as fallback
                        const attrs = blk: {
                            // Check if view specifies attribute filtering
                            if (view.view.attribute_allowed_keys) |_| {
                                // View specifies attributes, use view's transform
                                break :blk view.transformAttributes(attributes, allocator) catch |e| {
                                    api.common.reportErrorWithAllocator(.{
                                        .component = .meter,
                                        .context = null,
                                        .error_type = .internal,
                                        .message = "Unable to transform attributes with view",
                                        .operation = @tagName(inst_type) ++ ".add(" ++ @typeName(ValueType) ++ ")",
                                        .source_error = e,
                                    }, allocator);
                                    break :blk attributes; // On error, use original attributes
                                };
                            } else if (self.advisory_params) |advisory| {
                                // No view attribute filtering, check advisory params (Development status)
                                if (advisory.attributes) |allowed_keys| {
                                    // Filter to advisory-specified attributes
                                    var filtered = std.ArrayList(api.AttributeKeyValue).empty;
                                    defer filtered.deinit(allocator);

                                    for (attributes) |attr| {
                                        for (allowed_keys) |allowed_key| {
                                            if (std.mem.eql(u8, attr.key, allowed_key)) {
                                                filtered.append(allocator, attr) catch break :blk attributes;
                                                break;
                                            }
                                        }
                                    }

                                    break :blk filtered.toOwnedSlice(allocator) catch attributes;
                                } else {
                                    // No advisory attributes, use all attributes
                                    break :blk view.transformAttributes(attributes, allocator) catch attributes;
                                }
                            } else {
                                // No view or advisory filtering, use all attributes
                                break :blk view.transformAttributes(attributes, allocator) catch attributes;
                            }
                        };

                        // Create transformed metadata
                        const metadata = sdk.MetricMetadata{
                            .name = view.getName(self.name),
                            .description = view.getDescription(self.description) orelse "",
                            .unit = self.unit orelse "", // Unit not transformable per spec
                            .instrument_type = inst_type,
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

                        // Forward to all readers
                        for (self.meter.provider.readers.items) |*reader| {
                            reader.recordMeasurement(switch (base_type) {
                                .int => .{ .i64 = value },
                                .float => .{ .f64 = value },
                            }, attrs, metadata, view_hash);
                        }
                    }
                }

                pub inline fn enabled(self: *const Self) bool {
                    _ = self;
                    return true;
                }
            };
        },
        .Gauge, .Histogram => blk: {
            break :blk struct {
                const Self = @This();
                name: []const u8,
                description: ?[]const u8,
                unit: ?[]const u8,
                meter: *sdk.Meter,
                metadata_hash: u64,
                views: []sdk.View.Application,
                advisory_params: ?api.metrics.AdvisoryParams,

                pub fn init(
                    name: []const u8,
                    description: ?[]const u8,
                    unit: ?[]const u8,
                    parent_meter: *sdk.Meter,
                    advisory_params: ?api.metrics.AdvisoryParams,
                ) !Self {
                    // Precompute the hash values that don't change per datapoint.
                    const metadata_hash = sdk.MetricMetadata.computeHash(
                        name,
                        unit orelse "",
                        inst_type,
                        &parent_meter.scope,
                    );

                    // Get the views that apply to this instrument.
                    const view_applications = try parent_meter.provider.applyViews(
                        name,
                        inst_type,
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

                    return .{
                        .name = name,
                        .description = description,
                        .unit = unit,
                        .meter = parent_meter,
                        .metadata_hash = metadata_hash,
                        .views = view_applications,
                        .advisory_params = owned_advisory_params,
                    };
                }

                pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                    // Free owned advisory params
                    if (self.advisory_params) |params| {
                        if (params.explicit_bucket_boundaries) |boundaries| {
                            allocator.free(boundaries);
                        }
                        if (params.attributes) |attrs| {
                            for (attrs) |attr| {
                                allocator.free(attr);
                            }
                            allocator.free(attrs);
                        }
                    }
                    allocator.free(self.views);
                }

                pub fn getName(self: *const Self) []const u8 {
                    return self.name;
                }

                pub fn record(self: *const Self, ctx: []const api.ContextKeyValue, value: ValueType, attributes: []const api.AttributeKeyValue) void {
                    _ = ctx;

                    // Create an arena, so we don't have to keep track of which slices are
                    // allocated here, and which are unowned.
                    var arena = std.heap.ArenaAllocator.init(self.meter.provider.allocator);
                    defer arena.deinit();
                    const allocator = arena.allocator();

                    // Process each view application
                    for (self.views) |view| {
                        // Skip drop aggregations
                        if (view.drops()) continue;

                        // Transform attributes according to view, with advisory params as fallback
                        const attrs = blk: {
                            // Check if view specifies attribute filtering
                            if (view.view.attribute_allowed_keys) |_| {
                                // View specifies attributes, use view's transform
                                break :blk view.transformAttributes(attributes, allocator) catch |e| {
                                    api.common.reportErrorWithAllocator(.{
                                        .component = .meter,
                                        .context = null,
                                        .error_type = .internal,
                                        .message = "Unable to transform attributes with view",
                                        .operation = @tagName(inst_type) ++ ".record(" ++ @typeName(ValueType) ++ ")",
                                        .source_error = e,
                                    }, allocator);
                                    break :blk attributes; // On error, use original attributes
                                };
                            } else if (self.advisory_params) |advisory| {
                                // No view attribute filtering, check advisory params (Development status)
                                if (advisory.attributes) |allowed_keys| {
                                    // Filter to advisory-specified attributes
                                    var filtered = std.ArrayList(api.AttributeKeyValue).empty;
                                    defer filtered.deinit(allocator);

                                    for (attributes) |attr| {
                                        for (allowed_keys) |allowed_key| {
                                            if (std.mem.eql(u8, attr.key, allowed_key)) {
                                                filtered.append(allocator, attr) catch break :blk attributes;
                                                break;
                                            }
                                        }
                                    }

                                    break :blk filtered.toOwnedSlice(allocator) catch attributes;
                                } else {
                                    // No advisory attributes, use all attributes
                                    break :blk view.transformAttributes(attributes, allocator) catch attributes;
                                }
                            } else {
                                // No view or advisory filtering, use all attributes
                                break :blk view.transformAttributes(attributes, allocator) catch attributes;
                            }
                        };

                        // Create transformed metadata
                        const metadata = sdk.MetricMetadata{
                            .name = view.getName(self.name),
                            .description = view.getDescription(self.description) orelse "",
                            .unit = self.unit orelse "", // Unit not transformable per spec
                            .instrument_type = inst_type,
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

                        // Forward to all readers
                        for (self.meter.provider.readers.items) |*reader| {
                            reader.recordMeasurement(switch (base_type) {
                                .int => .{ .i64 = value },
                                .float => .{ .f64 = value },
                            }, attrs, metadata, view_hash);
                        }
                    }
                }

                pub fn enabled(self: *const Self) bool {
                    _ = self;
                    return true;
                }
            };
        },
        else => unreachable,
    };
}

pub fn StandardCounter(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.Counter, Base);
}

pub fn StandardUpDownCounter(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.UpDownCounter, Base);
}

pub fn StandardGauge(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.Gauge, Base);
}

pub fn StandardHistogram(comptime value_type: type) type {
    const Base = switch (value_type) {
        i64 => BaseType.int,
        f64 => BaseType.float,
        else => unreachable,
    };
    return Instrument(.Histogram, Base);
}
