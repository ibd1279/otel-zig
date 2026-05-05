//! OpenTelemetry Semantic Conventions v1.41.0
//!
//! Re-exports all signal-specific convention modules.  Each module
//! exposes SCREAMING_SNAKE_CASE string constants for attribute keys and
//! metric names, plus CamelCase structs for known enum values.
//!
//! ## Usage
//! ```zig
//! const semconv = @import("otel-semconv");
//!
//! // Resource attributes
//! resource.addAttribute(semconv.resource.SERVICE_NAME, "my-service");
//!
//! // HTTP span attributes
//! span.setAttribute(semconv.http.REQUEST_METHOD, semconv.http.RequestMethod.GET);
//! span.setAttribute(semconv.http.RESPONSE_STATUS_CODE, 200);
//!
//! // GenAI attributes
//! span.setAttribute(semconv.gen_ai.PROVIDER_NAME, semconv.gen_ai.ProviderName.openai);
//! span.setAttribute(semconv.gen_ai.OPERATION_NAME, semconv.gen_ai.OperationName.chat);
//! ```

const std = @import("std");

// Signal-specific modules

pub const resource = @import("resource.zig");
pub const metrics = @import("metrics.zig");
pub const logs = @import("logs.zig");
pub const exception = @import("exception.zig");

// Protocol / domain modules

pub const http = @import("http.zig");
pub const net = @import("network.zig");
pub const db = @import("database.zig");
pub const messaging = @import("messaging.zig");
pub const rpc = @import("rpc.zig");

// AI / agent modules

pub const gen_ai = @import("gen_ai.zig");
pub const mcp = @import("mcp.zig");

// Version information

pub const SEMCONV_VERSION = "1.41.0";
pub const SCHEMA_URL = "https://opentelemetry.io/schemas/1.41.0";

test "semconv module compilation" {
    _ = std.testing;
    _ = resource;
    _ = metrics;
    _ = logs;
    _ = exception;
    _ = http;
    _ = net;
    _ = db;
    _ = messaging;
    _ = rpc;
    _ = gen_ai;
    _ = mcp;
}
