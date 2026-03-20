//! OpenTelemetry Trace API
//!
//! This module provides the tracing API according to the OpenTelemetry specification.
//! The API contains only interfaces and no-op implementations, allowing libraries to
//! instrument their code without depending on a specific SDK implementation.
//!
//! ## Components
//! - `Span` - Represents a unit of work within a trace
//! - `Tracer` - Creates spans
//! - `TracerProvider` - Factory for creating tracers
//! - `SpanContext` - Immutable span identifier
//! - `SpanKind` - Type of span (client, server, etc.)
//! - `StatusCode` - Span completion status
//!
//! ## Status
//! This is a placeholder implementation. Full trace support is planned for a future release.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md

const std = @import("std");
pub const StateKeyValue = @import("trace_state.zig").StateKeyValue;
pub const StateBuilder = @import("trace_state.zig").StateBuilder;
pub const OtState = @import("trace_state.zig").OtState;

// Context integration (Phase 2 - Implemented)
pub const context_keys = @import("context_keys.zig");
pub const W3cPropagator = @import("w3c_propagator.zig").W3cPropagator;
pub const createW3cPropagator = @import("w3c_propagator.zig").createW3cPropagator;
pub const spanContextFromHeaders = @import("w3c_propagator.zig").spanContextFromHeaders;

// Spans
const span_zig = @import("span.zig");
pub const Span = span_zig.Span;

pub const sampling_config = @import("sampling_config.zig");
pub const Sampler = sampling_config.Sampler;

// Re-export commonly used context utilities for convenience
pub const trace_context = @import("context_utils.zig");
pub const getActiveSpan = @import("context_utils.zig").getActiveSpan;

// Core interfaces (Phase 4 - Implemented)
pub const tracer_zig = @import("tracer.zig");
pub const Tracer = tracer_zig.Tracer;

pub const TracerBridge = tracer_zig.TracerBridge;
pub const TracerProvider = @import("tracer_provider.zig").TracerProvider;
pub const TracerProviderBridge = @import("tracer_provider.zig").TracerProviderBridge;

// Validation functions for SDK use
pub const validateSpanName = span_zig.validateSpanName;
pub const validateAttributeValue = tracer_zig.validateAttributeValue;
pub const validateAttributes = tracer_zig.validateAttributes;

// Tests
test "trace api module compilation" {
    std.testing.refAllDecls(@This());
}
