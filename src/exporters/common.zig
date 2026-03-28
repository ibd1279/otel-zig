//! OpenTelemetry Exporters Common Types
//!
//! This module provides common types and utilities shared across all exporters.
//! These include result types, error types, and common configuration structures.

const std = @import("std");


/// Errors that can occur during export operations
pub const ExportError = error{
    /// Export operation timed out
    Timeout,

    /// Network or connection error
    ConnectionError,

    /// Invalid data or serialization error
    InvalidData,

    /// Exporter has been shut down
    ExporterShutdown,

    /// Resource exhausted (e.g., queue full)
    ResourceExhausted,

    /// Authentication or authorization failure
    AuthenticationError,

    /// Server returned an error
    ServerError,

    /// Configuration error
    ConfigurationError,

    /// Unknown or unspecified error
    UnknownError,
};

/// Common configuration for exporters
pub const ExporterConfig = struct {
    /// Timeout for export operations in milliseconds
    timeout_millis: u64 = 30000,

    /// Maximum number of retries for failed exports
    max_retries: u32 = 3,

    /// Backoff multiplier for retries
    retry_backoff_multiplier: f64 = 2.0,

    /// Maximum backoff time in milliseconds
    max_retry_backoff_millis: u64 = 60000,

    /// Whether to compress payloads
    compression_enabled: bool = false,

    /// Headers to include with requests (for network exporters)
    headers: []const Header = &[_]Header{},

    /// TLS configuration (for network exporters)
    tls_config: ?TlsConfig = null,
};

/// HTTP/gRPC header
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// TLS configuration
pub const TlsConfig = struct {
    /// Path to CA certificate file
    ca_file: ?[]const u8 = null,

    /// Path to client certificate file
    cert_file: ?[]const u8 = null,

    /// Path to client key file
    key_file: ?[]const u8 = null,

    /// Whether to skip certificate verification (insecure)
    insecure_skip_verify: bool = false,

    /// Server name for certificate verification
    server_name: ?[]const u8 = null,
};

/// Compression method
pub const CompressionMethod = enum {
    none,
    gzip,
    zstd,
};

/// Serialization format
pub const SerializationFormat = enum {
    /// Protocol Buffers binary format
    protobuf,

    /// JSON format
    json,

    /// MessagePack format
    msgpack,

    /// Custom format
    custom,
};

/// Export statistics for monitoring
pub const ExportStats = struct {
    /// Total number of successful exports
    success_count: u64 = 0,

    /// Total number of failed exports
    failure_count: u64 = 0,

    /// Total number of items exported
    exported_items: u64 = 0,

    /// Total number of items dropped
    dropped_items: u64 = 0,

    /// Last export timestamp
    last_export_time: ?std.Io.Timestamp = null,

    /// Last export duration in milliseconds
    last_export_duration_ms: ?u64 = null,

    /// Average export duration in milliseconds
    avg_export_duration_ms: f64 = 0,

    pub fn recordSuccess(self: *ExportStats, items: u64, duration_ms: u64) void {
        self.success_count += 1;
        self.exported_items += items;
        self.last_export_time = std.Io.Timestamp.zero;
        self.last_export_duration_ms = duration_ms;

        // Update average duration
        const total_exports = self.success_count + self.failure_count;
        self.avg_export_duration_ms = (self.avg_export_duration_ms * @as(f64, @floatFromInt(total_exports - 1)) + @as(f64, @floatFromInt(duration_ms))) / @as(f64, @floatFromInt(total_exports));
    }

    pub fn recordFailure(self: *ExportStats, items: u64) void {
        self.failure_count += 1;
        self.dropped_items += items;
        self.last_export_time = std.Io.Timestamp.zero;
    }
};

/// Batch configuration for batch exporters
pub const BatchConfig = struct {
    /// Maximum number of items in a batch
    max_batch_size: usize = 512,

    /// Maximum time to wait before exporting a batch (milliseconds)
    max_export_delay_millis: u64 = 5000,

    /// Maximum number of items to queue
    max_queue_size: usize = 2048,
};

/// Retry configuration
pub const RetryConfig = struct {
    /// Whether retries are enabled
    enabled: bool = true,

    /// Initial retry delay in milliseconds
    initial_delay_millis: u64 = 1000,

    /// Maximum retry delay in milliseconds
    max_delay_millis: u64 = 60000,

    /// Maximum number of retry attempts
    max_attempts: u32 = 3,

    /// Backoff multiplier
    backoff_multiplier: f64 = 2.0,

    /// Add jitter to retry delays
    jitter_enabled: bool = true,
};

test "ExportStats operations" {
    const testing = std.testing;

    var stats = ExportStats{};

    stats.recordSuccess(100, 50);
    try testing.expectEqual(@as(u64, 1), stats.success_count);
    try testing.expectEqual(@as(u64, 100), stats.exported_items);
    try testing.expectEqual(@as(u64, 50), stats.last_export_duration_ms.?);
    try testing.expectEqual(@as(f64, 50), stats.avg_export_duration_ms);

    stats.recordSuccess(200, 100);
    try testing.expectEqual(@as(u64, 2), stats.success_count);
    try testing.expectEqual(@as(u64, 300), stats.exported_items);
    try testing.expectEqual(@as(u64, 100), stats.last_export_duration_ms.?);
    try testing.expectEqual(@as(f64, 75), stats.avg_export_duration_ms);

    stats.recordFailure(50);
    try testing.expectEqual(@as(u64, 1), stats.failure_count);
    try testing.expectEqual(@as(u64, 50), stats.dropped_items);
}
