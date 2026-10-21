//! OpenTelemetry Protocol (OTLP) Exporters
//!
//! This module provides exporters that use the OpenTelemetry Protocol (OTLP)
//! to send telemetry data to OTLP-compatible backends such as:
//! - OpenTelemetry Collector
//! - Cloud providers (AWS X-Ray, Google Cloud Trace, etc.)
//! - Commercial APM solutions
//!
//! ## Transport Options
//! The trace exporter supports HTTP with JSON or protobuf payloads. Its
//! `grpc` transport value is reserved and currently returns an unsupported
//! transport error.
//!
//! ## Configuration
//! All OTLP exporters share common configuration:
//! - `endpoint` - The OTLP receiver endpoint
//! - `headers` - Additional headers for authentication
//! - `timeout` - Request timeout
//!
//! ## Usage
//! ```zig
//! const otlp_exporter = createLogExporter(.{
//!     .endpoint = "http://localhost:4317",
//!     .headers = &.{.{ "api-key", "secret" }},
//! });
//! ```
//!
//! Trace exports honor endpoint paths, custom headers, gzip compression, and
//! request timeouts. Log and metric exporter capabilities are documented by
//! their respective modules.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");

// Re-export types
pub const OtlpLogExporter = @import("logs.zig").OtlpLogExporter;
pub const OtlpTraceExporter = @import("traces.zig").OtlpTraceExporter;
pub const transport = @import("transport_backend.zig").transport;
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

    /// Maximum duration of one complete export, including retries. This is
    /// the OTLP trace exporter's realization of the BSP export timeout.
    export_timeout_millis: u64 = 30000,

    /// Generic OTLP endpoints append the per-signal path; a traces-specific
    /// endpoint is already complete and sets this false.
    append_signal_path: bool = true,

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

/// Retry/backoff configuration for OTLP exports.
///
/// This is the backend-agnostic retry contract every transport backend
/// (default std.http and opt-in httpx.zig via `-Dotlp-httpx`) must honor;
/// see the "OTLP/HTTP Transport Backends and the Retry Contract" section in
/// README.md for the full normative text:
///   - Overall budget: `min(max_elapsed_time_millis, export_timeout_millis)`;
///     a zero `max_elapsed_time_millis` means the export timeout alone.
///   - Per-attempt timeout: `min(timeout_millis, remaining budget)`.
///   - Backoff: exponential from `initial_interval_millis` scaled by
///     `multiplier` up to `max_interval_millis`; with `jitter` set the delay
///     is uniform in `[interval/2, interval*3/2]`.
///   - `Retry-After`: a server-provided value on a retryable response wins
///     over the computed backoff for that attempt.
///   - Retryable statuses: exactly 429, 502, 503, 504.
pub const RetryConfig = struct {
    enabled: bool = true,
    initial_interval_millis: u64 = 5000,
    max_interval_millis: u64 = 30000,
    max_elapsed_time_millis: u64 = 60000,
    multiplier: f64 = 1.5,
    jitter: bool = true,
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
