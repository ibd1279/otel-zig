//! OpenTelemetry Baggage API
//!
//! This module provides the baggage API according to the OpenTelemetry specification.
//! Baggage is used to propagate user-supplied key-value pairs across process boundaries.
//!
//! ## Components
//! - `BaggageKeyValue` - Individual baggage entry with value and optional metadata
//!
//! ## Usage
//! ```zig
//! const otel_api = @import("otel-api");
//! const allocator = std.heap.page_allocator;
//!
//! // Create baggage entries
//! const entry1 = otel_api.baggage.BaggageKeyValue.init("user.id", "12345", null);
//! const entry2 = otel_api.baggage.BaggageKeyValue.init("session.id", "abcdef", null);
//!
//! // Create owned entries
//! const owned_entry = try otel_api.baggage.BaggageKeyValue.initOwned(allocator, "key", "value", null);
//! defer owned_entry.deinitOwned(allocator);
//! ```
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/baggage/api.md

const std = @import("std");

// Re-export baggage types
pub const BaggageKeyValue = @import("baggage.zig").BaggageKeyValue;
pub const BaggageBuilder = @import("baggage.zig").BaggageBuilder;
pub const BaggagePropagator = @import("propagator.zig").BaggagePropagator;

// Re-export factory functions

test {
    std.testing.refAllDecls(@This());
}
