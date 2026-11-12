//! OpenTelemetry Exception Semantic Conventions
//!
//! The spec-defined exception attributes, shared across span events and log records.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.45.0/model/exceptions

pub const TYPE = "exception.type";
pub const MESSAGE = "exception.message";
pub const STACKTRACE = "exception.stacktrace";
