//! OpenTelemetry RPC Semantic Conventions
//!
//! Attributes for Remote Procedure Call (RPC) instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.45.0/model/rpc

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

// Status

pub const STATUS_CODE = "rpc.status_code";

// Headers (template base)

/// Template base — append `.<lowercase-key>` to form the full key.
pub const REQUEST_HEADER = "rpc.request.header";

// Metrics

pub const SERVER_CALL_DURATION = "rpc.server.call.duration";
pub const CLIENT_CALL_DURATION = "rpc.client.call.duration";
