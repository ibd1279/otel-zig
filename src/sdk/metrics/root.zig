//! OpenTelemetry Metrics SDK
//!
//! This module provides the SDK implementation for OpenTelemetry metrics.
//! It includes concrete implementations of meters, instruments, and providers
//! that can be used to collect and export metrics.
//!
//!
const std = @import("std");

// MeterProvider exports
pub const MeterProvider = @import("meter_provider.zig").MeterProvider;
pub const Meter = @import("meter.zig").Meter;

// Processor and exporter types
pub const reader = @import("reader.zig");
pub const Reader = reader.Reader;
pub const BridgeReader = reader.BridgeReader;
pub const ManualReader = @import("manual_reader.zig").ManualReader;
pub const PeriodicReader = @import("periodic_reader.zig").PeriodicReader;

// Reader construction options (cardinality limit) and the default limit, so
// applications can size the per-cycle series budget without importing SDK
// internals.
pub const ReaderOptions = @import("reader_aggregation_state.zig").ReaderOptions;
pub const DEFAULT_CARDINALITY_LIMIT = @import("attribute_aggregation_map.zig").AttributeAggregationMap.DEFAULT_CARDINALITY_LIMIT;

const data_zig = @import("data.zig");
pub const MetricData = data_zig.MetricData;
pub const MetricDataPoint = data_zig.MetricDataPoint;
pub const MetricType = data_zig.MetricType;
pub const MetricValue = data_zig.MetricValue;
pub const I64HistogramData = data_zig.I64HistogramData;
pub const F64HistogramData = data_zig.F64HistogramData;

// View system exports
pub const View = @import("view.zig");

// aggregation types.
pub const AggregationType = @import("aggregations.zig").AggregationType;

// Exporter types.
const exporter_zig = @import("exporter.zig");
pub const MetricExporter = exporter_zig.MetricExporter;
pub const BridgeMetricExporter = exporter_zig.BridgeMetricExporter;

const async_instrument_zig = @import("async_instruments.zig");
pub const Observable = async_instrument_zig.Observable;
pub const AsyncInstrumentConfig = async_instrument_zig.AsyncInstrumentConfig;
pub const CallbackErrorPolicy = async_instrument_zig.CallbackErrorPolicy;

// Re-export the setup helper functions
pub const setupGlobalProvider = @import("setup.zig").setupGlobalProvider;
pub const setupGlobalProviderWithViews = @import("setup.zig").setupGlobalProviderWithViews;

test {
    _ = @import("test.zig");
    std.testing.refAllDecls(@This());
}
