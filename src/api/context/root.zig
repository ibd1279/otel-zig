//! OpenTelemetry Context API
//!
//! This module provides the context propagation API according to the OpenTelemetry specification.
//! Context is used to propagate values across API boundaries and between threads.
//!
//! The API provides a minimal interface for context management. Concrete implementations
//! are provided by the SDK.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/context/context.md

const std = @import("std");

// Re-export context types
pub const ContextBuilder = @import("context.zig").ContextBuilder;
pub const ContextKeyValue = @import("context.zig").ContextKeyValue;
pub const ContextKey = @import("context_key.zig").ContextKey;
pub const ContextValue = @import("context_key.zig").ContextValue;

// Re-export propagation types
pub const TextMapCarrier = @import("propagation.zig").TextMapCarrier;
pub const TextMapPropagator = @import("propagation.zig").TextMapPropagator;

// Implicit thread-local context propagation
pub const implicit = @import("implicit.zig");

test {
    std.testing.refAllDecls(@This());
}
