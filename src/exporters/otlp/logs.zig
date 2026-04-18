const std = @import("std");
const api = @import("otel-api");
const sdk = @import("otel-sdk");
const protobuf = @import("protobuf");

const LogRecord = sdk.logs.LogRecord;
const ExportResult = api.common.ExportResult;
const OtlpExporterConfig = @import("root.zig").OtlpExporterConfig;
const Resource = sdk.resource.Resource;
const ResourceBuilder = sdk.resource.ResourceBuilder;
const convert = @import("convert.zig");

// Import protobuf definitions
const logs_v1 = @import("proto/opentelemetry/proto/logs/v1.pb.zig");
const common_v1 = @import("proto/opentelemetry/proto/common/v1.pb.zig");
const resource_v1 = @import("proto/opentelemetry/proto/resource/v1.pb.zig");

const error_handler = api.common;

pub const OtlpLogExporter = struct {
    pub const PipelineStep = sdk.common.PipelineStepInstructions(
        OtlpLogExporter,
        sdk.logs.LogRecordExporter,
        OtlpExporterConfig,
        logRecordExporter,
        _init,
        sdk.common.PipelineDeinitConnection,
    );

    config: OtlpExporterConfig,
    allocator: std.mem.Allocator,
    is_shutdown: bool,
    mutex: std.Io.Mutex,

    pub fn _init(self: *OtlpLogExporter, config: OtlpExporterConfig, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, config);
    }

    pub fn init(allocator: std.mem.Allocator, config: OtlpExporterConfig) OtlpLogExporter {
        return .{
            .config = config,
            .allocator = allocator,
            .is_shutdown = false,
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *OtlpLogExporter) void {
        _ = self;
    }

    pub fn destroy(self: *OtlpLogExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportRecords(self: *OtlpLogExporter, records: []const LogRecord, resource: Resource) ExportResult {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        if (self.is_shutdown) {
            return .failure;
        }

        // Local arena for the OTLP transform and network send.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Choose format based on transport configuration
        const data_result = switch (self.config.transport) {
            .http_json => self.convertToJsonFormat(arena.allocator(), records, resource),
            .http_protobuf, .grpc => self.convertToProtobufFormat(arena.allocator(), records, resource),
        };

        const data = data_result catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_serialization",
                .error_type = .serialization,
                .message = "OTLP serialization failed",
                .context = "log records",
                .source_error = err,
            });
            return .failure;
        };

        const result = self.sendRequest(arena.allocator(), data) catch |err| {
            error_handler.reportError(.{
                .component = .exporter,
                .operation = "otlp_network",
                .error_type = .network,
                .message = "OTLP network request failed",
                .context = self.config.endpoint,
                .source_error = err,
            });
            return .failure;
        };

        return result;
    }

    pub fn forceFlush(self: *OtlpLogExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        // No-op for OTLP exporter
        return .success;
    }

    pub fn shutdown(self: *OtlpLogExporter, timeout_ms: ?u64) ExportResult {
        _ = timeout_ms;
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);

        if (self.is_shutdown) {
            return .failure;
        }

        self.is_shutdown = true;
        return .success;
    }

    fn sendRequest(self: *OtlpLogExporter, allocator: std.mem.Allocator, data: []const u8) !ExportResult {
        // Create stack-based HTTP client
        var client = std.http.Client{ .allocator = self.allocator, .io = self.config.io };
        defer client.deinit();

        // Parse endpoint URL with detailed error context
        const uri = std.Uri.parse(self.config.endpoint) catch |err| {
            return err;
        };

        // Build full URL with logs path
        const host_str = switch (uri.host.?) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        const scheme_str = if (uri.scheme.len > 0) uri.scheme else "http";
        const full_url = try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ scheme_str, host_str, uri.port orelse 4318, self.config.protocol_config.logs_path });
        defer allocator.free(full_url);

        // Determine content type based on transport
        const content_type = switch (self.config.transport) {
            .http_json => "application/json",
            .http_protobuf, .grpc => "application/x-protobuf",
        };

        // Add custom headers from config (simplified approach)
        var extra_headers = try allocator.alloc(std.http.Header, self.config.headers.len);
        defer allocator.free(extra_headers);
        for (self.config.headers, 0..) |header, h| {
            extra_headers[h] = header;
        }

        const full_uri = try std.Uri.parse(full_url);
        var req = try client.request(.POST, full_uri, .{
            .headers = .{
                .content_type = .{ .override = content_type },
                .user_agent = .{ .override = "otel-zig-otlp" },
            },
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        // Set request headers
        req.transfer_encoding = .{ .content_length = @intCast(data.len) };

        // Send request
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(data);
        try bw.end();
        try req.connection.?.flush();

        const res = try req.receiveHead(&.{});

        switch (res.head.status) {
            .ok => return .success,
            .bad_request, .unauthorized, .forbidden, .not_found => {
                return .failure;
            },
            else => {
                return .failure;
            },
        }
    }

    pub fn logRecordExporter(self: *OtlpLogExporter) sdk.logs.LogRecordExporter {
        return sdk.logs.LogRecordExporter{ .bridge = sdk.logs.BridgeLogRecordExporter.init(self) };
    }

    fn convertToJsonFormat(self: *OtlpLogExporter, allocator: std.mem.Allocator, records: []const LogRecord, resource: Resource) ![]u8 {
        _ = self;

        // Create protobuf LogsData structure
        var logs_data = try convertToProtoLogsData(allocator, records, resource);

        // Serialize to JSON
        return @constCast(try logs_data.jsonEncode(.{}, .{}, allocator));
    }

    fn convertToProtobufFormat(self: *OtlpLogExporter, allocator: std.mem.Allocator, records: []const LogRecord, resource: Resource) ![]u8 {
        _ = self;

        // Create protobuf LogsData structure
        var logs_data = try convertToProtoLogsData(allocator, records, resource);

        // Serialize to protobuf binary format
        var proto_buffer = std.Io.Writer.Allocating.init(allocator);
        defer proto_buffer.deinit();
        try logs_data.encode(&proto_buffer.writer, allocator);
        return proto_buffer.toOwnedSlice();
    }
};

fn convertToProtoLogsData(allocator: std.mem.Allocator, records: []const LogRecord, resource: Resource) !logs_v1.LogsData {
    // Create protobuf LogsData structure
    var logs_data = logs_v1.LogsData{};

    // Convert resource
    var resource_logs = logs_v1.ResourceLogs{
        .resource = try convert.resourceToProto(allocator, resource),
    };

    // Convert scope logs
    const MapType = std.HashMapUnmanaged(api.InstrumentationScope, std.ArrayList(LogRecord), sdk.common.InstrumentationScopeMapContext, 80);
    var scope_map = MapType.empty;
    defer {
        var it = scope_map.iterator();
        while (it.next()) |scope_entry| {
            scope_entry.value_ptr.deinit(allocator);
        }
        scope_map.deinit(allocator);
    }

    for (records) |record| {
        const result = try scope_map.getOrPut(allocator, record.instrumentation_scope orelse api.InstrumentationScope.empty);
        if (!result.found_existing) result.value_ptr.* = .empty;
        try result.value_ptr.append(allocator, record);
    }

    var iter = scope_map.iterator();
    while (iter.next()) |scope_entry| {
        var scope_logs = logs_v1.ScopeLogs{
            .scope = try convert.instrumentationScopeToProto(allocator, scope_entry.key_ptr.*),
            .schema_url = scope_entry.key_ptr.schema_url orelse &.{},
        };

        for (scope_entry.value_ptr.*.items) |record| {
            const protobuf_record = try convertLogRecordToProtobuf(allocator, record);
            try scope_logs.log_records.append(allocator, protobuf_record);
        }

        try resource_logs.scope_logs.append(allocator, scope_logs);
    }

    try logs_data.resource_logs.append(allocator, resource_logs);

    return logs_data;
}

fn convertLogRecordToProtobuf(allocator: std.mem.Allocator, record: LogRecord) !logs_v1.LogRecord {
    const ts_ns = if (record.timestamp) |ts| ts.toNanoseconds() else 0;
    const obs_ts_ns = if (record.observed_timestamp) |ts| ts.toNanoseconds() else ts_ns;
    var pb_record = logs_v1.LogRecord{
        .time_unix_nano = @as(u64, @intCast(@max(0, ts_ns))),
        .observed_time_unix_nano = @as(u64, @intCast(@max(0, obs_ts_ns))),
        .severity_number = mapSeverityToProtobuf(record.severity_number),
        .severity_text = record.severity_number.toShortText(),
        .body = if (record.body) |body| try convert.attributeValueToProto(allocator, body) else null,
        .event_name = record.event_name orelse &.{},
        .flags = record.flags orelse 0,
        .trace_id = if (record.trace_id) |tid| try allocator.dupe(u8, &tid.bytes) else &.{},
        .span_id = if (record.span_id) |sid| try allocator.dupe(u8, &sid.bytes) else &.{},
        .dropped_attributes_count = 0,
    };

    for (record.attributes) |attr| {
        try pb_record.attributes.append(allocator, try convert.attributeKeyValueToProto(allocator, attr));
    }

    return pb_record;
}

fn mapSeverityToProtobuf(severity: api.logs.Severity) logs_v1.SeverityNumber {
    return switch (severity) {
        .invalid => .SEVERITY_NUMBER_UNSPECIFIED,
        .trace => .SEVERITY_NUMBER_TRACE,
        .trace2 => .SEVERITY_NUMBER_TRACE2,
        .trace3 => .SEVERITY_NUMBER_TRACE3,
        .trace4 => .SEVERITY_NUMBER_TRACE4,
        .debug => .SEVERITY_NUMBER_DEBUG,
        .debug2 => .SEVERITY_NUMBER_DEBUG2,
        .debug3 => .SEVERITY_NUMBER_DEBUG3,
        .debug4 => .SEVERITY_NUMBER_DEBUG4,
        .info => .SEVERITY_NUMBER_INFO,
        .info2 => .SEVERITY_NUMBER_INFO2,
        .info3 => .SEVERITY_NUMBER_INFO3,
        .info4 => .SEVERITY_NUMBER_INFO4,
        .warn => .SEVERITY_NUMBER_WARN,
        .warn2 => .SEVERITY_NUMBER_WARN2,
        .warn3 => .SEVERITY_NUMBER_WARN3,
        .warn4 => .SEVERITY_NUMBER_WARN4,
        .@"error" => .SEVERITY_NUMBER_ERROR,
        .error2 => .SEVERITY_NUMBER_ERROR2,
        .error3 => .SEVERITY_NUMBER_ERROR3,
        .error4 => .SEVERITY_NUMBER_ERROR4,
        .fatal => .SEVERITY_NUMBER_FATAL,
        .fatal2 => .SEVERITY_NUMBER_FATAL2,
        .fatal3 => .SEVERITY_NUMBER_FATAL3,
        .fatal4 => .SEVERITY_NUMBER_FATAL4,
    };
}

test "OtlpLogExporter basic functionality" {
    // Skipped: exportRecords requires a valid std.Io handle in 0.16 for HTTP.
    // This test makes a real network call (to localhost:4318) which needs io from main().
    return error.SkipZigTest;
}

test "OtlpLogExporter transport selection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test resource
    const resource = try Resource.initOwned(allocator, .default);
    defer resource.deinitOwned(allocator);

    // Create test log record
    const log_record = LogRecord{
        .timestamp = std.Io.Timestamp.fromNanoseconds(1000000000),
        .severity_number = .info,
        .body = .{ .string = "test message" },
        .attributes = &[_]api.common.AttributeKeyValue{
            .{ .key = "test.key", .value = .{ .string = "test.value" } },
        },
    };

    // Test JSON transport
    {
        const config = OtlpExporterConfig{
            .io = std.testing.io,
            .endpoint = "http://localhost:4318",
            .transport = .http_json,
        };

        var exporter = OtlpLogExporter.init(allocator, config);
        defer exporter.deinit();

        // Test JSON format conversion
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const json_data = try exporter.convertToJsonFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);
        try testing.expect(json_data.len > 0);
        try testing.expect(std.mem.find(u8, json_data, "test message") != null);
        try testing.expect(std.mem.find(u8, json_data, "test.key") != null);
        try testing.expect(std.mem.find(u8, json_data, "telemetry.sdk.name") != null);
    }

    // Test protobuf transport
    {
        const config = OtlpExporterConfig{
            .io = std.testing.io,
            .endpoint = "http://localhost:4318",
            .transport = .http_protobuf,
        };

        var exporter = OtlpLogExporter.init(allocator, config);
        defer exporter.deinit();

        // Test protobuf format conversion
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const protobuf_data = try exporter.convertToProtobufFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);
        try testing.expect(protobuf_data.len > 0);
        // Protobuf is binary format, so we can't check for string content directly
        // But we can verify it's not empty and different from JSON
    }

    // Test gRPC transport (should use protobuf format)
    {
        const config = OtlpExporterConfig{
            .io = std.testing.io,
            .endpoint = "http://localhost:4318",
            .transport = .grpc,
        };

        var exporter = OtlpLogExporter.init(allocator, config);
        defer exporter.deinit();

        // Test gRPC format conversion (should be same as protobuf)
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const grpc_data = try exporter.convertToProtobufFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);
        try testing.expect(grpc_data.len > 0);
    }
}

test "OtlpLogExporter severity mapping" {
    const testing = std.testing;

    // Test all severity levels map correctly
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_UNSPECIFIED, mapSeverityToProtobuf(.invalid));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_TRACE, mapSeverityToProtobuf(.trace));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_DEBUG, mapSeverityToProtobuf(.debug));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_INFO, mapSeverityToProtobuf(.info));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_WARN, mapSeverityToProtobuf(.warn));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_ERROR, mapSeverityToProtobuf(.@"error"));
    try testing.expectEqual(logs_v1.SeverityNumber.SEVERITY_NUMBER_FATAL, mapSeverityToProtobuf(.fatal));
}

test "OtlpLogExporter protobuf format validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test resource
    const resource = try Resource.initOwned(allocator, .default);
    defer resource.deinitOwned(allocator);

    // Create test log record
    const log_record = LogRecord{
        .timestamp = std.Io.Timestamp.fromNanoseconds(1000000000),
        .severity_number = .info,
        .body = .{ .string = "test message" },
        .attributes = &[_]api.common.AttributeKeyValue{
            .{ .key = "test.key", .value = .{ .string = "test.value" } },
            .{ .key = "test.number", .value = .{ .int = 42 } },
        },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var exporter = OtlpLogExporter.init(allocator, .{ .io = std.testing.io, .transport = .http_json });

    // Generate JSON using protobuf structures
    const protobuf_json = try exporter.convertToJsonFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);

    // Generate binary protobuf
    const protobuf_data = try exporter.convertToProtobufFormat(arena.allocator(), &[_]LogRecord{log_record}, resource);

    // Validate both formats are generated successfully
    try testing.expect(protobuf_json.len > 0);
    try testing.expect(protobuf_data.len > 0);

    // Protobuf binary should be smaller than JSON
    try testing.expect(protobuf_data.len < protobuf_json.len);

    // JSON should contain the test message and attributes
    try testing.expect(std.mem.find(u8, protobuf_json, "test message") != null);
    try testing.expect(std.mem.find(u8, protobuf_json, "test.key") != null);
    try testing.expect(std.mem.find(u8, protobuf_json, "test.value") != null);

    // JSON should contain OTLP structure
    try testing.expect(std.mem.find(u8, protobuf_json, "resourceLogs") != null);
    try testing.expect(std.mem.find(u8, protobuf_json, "scopeLogs") != null);
    try testing.expect(std.mem.find(u8, protobuf_json, "logRecords") != null);
}
