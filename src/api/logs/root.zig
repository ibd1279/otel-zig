//! OpenTelemetry Logs API
//!
//! This module provides the logging API according to the OpenTelemetry specification.
//! The API contains only interfaces and no-op implementations, allowing libraries to
//! instrument their code without depending on a specific SDK implementation.
//!
//! ## Components
//! - `Severity` - Log severity levels with OpenTelemetry standard values
//! - `LogRecord` - Log record structure
//! - `Logger` - Logger interface with no-op implementation
//! - `LoggerProvider` - Factory for creating and managing loggers
//!
//! ## Usage
//! ```zig
//! const otel_api = @import("otel-api");
//! const scope = otel_api.InstrumentationScope{ .name = "my.library" };
//! var logger = otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);
//! logger.emitLog(&.{}, .info, "Operation completed");
//! ```

const std = @import("std");

// Core types
const severity_zig = @import("severity.zig");
pub const Severity = severity_zig.Severity;
pub const SeverityError = severity_zig.SeverityError;
pub const fromNumber = severity_zig.fromNumber;
pub const fromText = severity_zig.fromText;

// Logger types
const logger_zig = @import("logger.zig");
pub const Logger = logger_zig.Logger;
pub const LoggerBridge = logger_zig.LoggerBridge;

// Validation functions for SDK use
pub const validateSeverity = logger_zig.validateSeverity;
pub const validateLogBody = logger_zig.validateLogBody;
pub const validateLogAttributes = logger_zig.validateLogAttributes;
pub const validateEventName = logger_zig.validateEventName;
pub const validateSeverityText = logger_zig.validateSeverityText;
pub const validateFormatString = logger_zig.validateFormatString;
pub const validateAttributes = logger_zig.validateAttributes;
pub const validateTraceId = @import("../common/types.zig").validateTraceId;
pub const validateSpanId = @import("../common/types.zig").validateSpanId;
pub const validateTraceFlags = @import("../common/types.zig").validateTraceFlags;

// Logger provider types
const logger_provider_zig = @import("logger_provider.zig");
pub const LoggerProvider = logger_provider_zig.LoggerProvider;
pub const LoggerProviderBridge = logger_provider_zig.LoggerProviderBridge;

test "logs api module compilation" {
    std.testing.refAllDecls(@This());
}
