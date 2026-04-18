//! OpenTelemetry SDK Trace
//!
//! This module provides concrete implementations of the OpenTelemetry Trace API.
//! The SDK includes span processors, exporters, and configurable tracing pipelines.
//!
//! ## Components
//! - `RecordingSpan` - Concrete span implementation with full functionality
//! - `StandardTracer` - Concrete tracer that creates spans
//! - `TracerProvider` - Provider with configuration and span processors
//! - `SpanProcessor` - Interface for processing spans
//! - `SimpleSpanProcessor` - Immediately exports each span
//! - `SpanExporter` - Interface for exporting spans
//!
//! ## Usage
//! ```zig
//! const otel_sdk = @import("otel-sdk");
//!
//! // Setup tracing pipeline using setupGlobalProvider
//! const trace_provider = try otel_sdk.trace.setupGlobalProvider(
//!     allocator,
//!     .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
//!         .flowTo(otel_sdk.exporters.console.ConsoleTraceExporter.PipelineStep.init(.{}))},
//! );
//! defer {
//!     trace_provider.deinit();
//!     trace_provider.destroy();
//! }
//! ```

const std = @import("std");
const otel_api = @import("otel-api");

// Core types
pub const RecordingSpan = @import("data.zig").RecordingSpan;
pub const SpanData = @import("data.zig").SpanData;
pub const StandardTracer = @import("tracer.zig").StandardTracer;
pub const TracerProvider = @import("tracer_provider.zig").TracerProvider;

// Processor types
pub const SpanProcessor = @import("processor.zig").SpanProcessor;
pub const BasicSpanProcessor = @import("basic_span_processor.zig").BasicSpanProcessor;
pub const SimpleSpanProcessor = @import("processor.zig").SimpleSpanProcessor;
pub const BatchSpanProcessor = @import("batch_span_processor.zig").BatchSpanProcessor;
pub const BridgeSpanProcessor = @import("processor.zig").BridgeSpanProcessor;

// Exporter types
pub const SpanExporter = @import("exporter.zig").SpanExporter;
pub const BridgeSpanExporter = @import("exporter.zig").BridgeSpanExporter;

// Samplers
pub const samplers = @import("samplers/root.zig");

// ID generation
pub const IdGenerator = @import("id_generator.zig").IdGenerator;
pub const RandomIdGenerator = @import("id_generator.zig").RandomIdGenerator;
pub const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;

// Resource type
const Resource = @import("../resource/resource.zig").Resource;

// Re-export the setup helper functions
pub const setupGlobalProvider = @import("setup.zig").setupGlobalProvider;

test {
    std.testing.refAllDecls(@This());
}
