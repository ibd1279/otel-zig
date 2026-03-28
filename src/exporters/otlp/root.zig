//! OpenTelemetry Protocol (OTLP) Exporters
//!
//! This module provides exporters that use the OpenTelemetry Protocol (OTLP)
//! to send telemetry data to OTLP-compatible backends such as:
//! - OpenTelemetry Collector
//! - Cloud providers (AWS X-Ray, Google Cloud Trace, etc.)
//! - Commercial APM solutions
//!
//! ## Transport Options
//! OTLP exporters support two transport mechanisms:
//! - **gRPC** - Binary protocol over HTTP/2 (default)
//! - **HTTP** - JSON or Protobuf over HTTP/1.1
//!
//! ## Configuration
//! All OTLP exporters share common configuration:
//! - `endpoint` - The OTLP receiver endpoint
//! - `headers` - Additional headers for authentication
//! - `timeout` - Request timeout
//! - `retry_config` - Retry behavior for failed exports
//!
//! ## Usage
//! ```zig
//! const otlp_exporter = createLogExporter(.{
//!     .endpoint = "http://localhost:4317",
//!     .headers = &.{.{ "api-key", "secret" }},
//! });
//! ```
//!
//! ## Status
//! This is a placeholder implementation. Full OTLP support is planned for a future release.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

// Re-export types
pub const OtlpLogExporter = @import("logs.zig").OtlpLogExporter;
pub const OtlpTraceExporter = @import("traces.zig").OtlpTraceExporter;
pub const OtlpMetricExporter = @import("metrics.zig").OtlpMetricExporter;

// Re-export creation functions
pub const createMetricExporterWithConfig = @import("metrics.zig").createMetricExporterWithConfig;
pub const createTraceExporter = @import("traces.zig").createTraceExporter;
pub const createTraceExporterWithConfig = @import("traces.zig").createTraceExporterWithConfig;

// Transport types
pub const Transport = enum {
    grpc,
    http_protobuf,
    http_json,
};

// OTLP-specific configuration
pub const OtlpExporterConfig = struct {
    /// Io handle required for HTTP transport.
    io: std.Io,

    /// OTLP receiver endpoint
    endpoint: []const u8 = "http://localhost:4318",

    /// Transport mechanism
    transport: Transport = .http_protobuf,

    /// Headers for authentication/metadata
    headers: []const std.http.Header = &[_]std.http.Header{},

    /// Compression method
    compression: CompressionMethod = .none,

    /// Request timeout in milliseconds
    timeout_millis: u64 = 10000,

    /// TLS configuration
    tls_config: ?TlsConfig = null,

    /// Retry configuration
    retry_config: RetryConfig = .{},

    /// Protocol-specific options
    protocol_config: ProtocolConfig = .{},
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const CompressionMethod = enum {
    none,
    gzip,
};

pub const TlsConfig = struct {
    insecure_skip_verify: bool = false,
    ca_file: ?[]const u8 = null,
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
};

pub const RetryConfig = struct {
    enabled: bool = true,
    initial_interval_millis: u64 = 1000,
    max_interval_millis: u64 = 60000,
    max_elapsed_time_millis: u64 = 300000,
    multiplier: f64 = 1.5,
};

pub const ProtocolConfig = struct {
    /// Maximum message size for gRPC
    max_message_size: usize = 4 * 1024 * 1024,

    /// Path for HTTP endpoints
    logs_path: []const u8 = "/v1/logs",
    traces_path: []const u8 = "/v1/traces",
    metrics_path: []const u8 = "/v1/metrics",
};

test {
    std.testing.refAllDecls(@This());
}
