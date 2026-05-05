//! OpenTelemetry RPC Semantic Conventions
//!
//! Attributes for Remote Procedure Call (RPC) instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model/rpc

// System

pub const SYSTEM_NAME = "rpc.system.name";

pub const SystemName = struct {
    pub const grpc = "grpc";
    pub const dubbo = "dubbo";
    pub const connectrpc = "connectrpc";
    pub const jsonrpc = "jsonrpc";
};

// Method

pub const METHOD = "rpc.method";
pub const METHOD_ORIGINAL = "rpc.method_original";

// Response

pub const RESPONSE_STATUS_CODE = "rpc.response.status_code";

// Metadata (template bases)

/// Template base — append `.<lowercase-key>` to form the full key.
pub const REQUEST_METADATA = "rpc.request.metadata";
/// Template base — append `.<lowercase-key>` to form the full key.
pub const RESPONSE_METADATA = "rpc.response.metadata";

// Metrics

pub const SERVER_CALL_DURATION = "rpc.server.call.duration";
pub const CLIENT_CALL_DURATION = "rpc.client.call.duration";
