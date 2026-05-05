//! OpenTelemetry Server Semantic Conventions
//!
//! Attributes describing the server side of a network connection.
//! Used on HTTP client spans, RPC client spans, database spans, and any
//! client-initiated connection where the remote end is a "server".
//! Spec: semantic-conventions/model/server/registry.yaml (v1.41.0)

// Stable

pub const ADDRESS = "server.address";
pub const PORT = "server.port";
