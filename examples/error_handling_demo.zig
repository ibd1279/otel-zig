//! Comprehensive Error Handling Demo
//!
//! This example demonstrates all aspects of error handling in OpenTelemetry Zig:
//! - Custom error handler setup
//! - Validation behavior in debug vs release modes
//! - Error classification and routing
//! - Performance monitoring
//! - Real-world error recovery patterns
//!
//! Run with:
//!   zig build && ./zig-out/bin/error_handling_demo
//!
//! To see validation in action, ensure you're running a debug build:
//!   zig build -Doptimize=Debug

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

/// Global error statistics for demonstration
const ErrorStats = struct {
    var total_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var validation_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var network_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var resource_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    fn incrementTotal() void {
        _ = total_errors.fetchAdd(1, .seq_cst);
    }

    fn incrementValidation() void {
        _ = validation_errors.fetchAdd(1, .seq_cst);
    }

    fn incrementNetwork() void {
        _ = network_errors.fetchAdd(1, .seq_cst);
    }

    fn incrementResource() void {
        _ = resource_errors.fetchAdd(1, .seq_cst);
    }

    fn printStats() void {
        const total = total_errors.load(.seq_cst);
        const validation = validation_errors.load(.seq_cst);
        const network = network_errors.load(.seq_cst);
        const resource = resource_errors.load(.seq_cst);

        std.debug.print("\n📊 Error Statistics:\n", .{});
        std.debug.print("  Total errors: {}\n", .{total});
        std.debug.print("  Validation: {}\n", .{validation});
        std.debug.print("  Network: {}\n", .{network});
        std.debug.print("  Resource: {}\n", .{resource});
        std.debug.print("  Other: {}\n\n", .{total - validation - network - resource});
    }
};

/// Custom error handler that demonstrates error classification and routing
fn customErrorHandler(info: otel_api.common.ErrorInfo, allocator: ?std.mem.Allocator) void {
    _ = allocator;

    ErrorStats.incrementTotal();

    // Route errors based on type and component
    switch (info.error_type) {
        .validation => handleValidationError(info),
        .network => handleNetworkError(info),
        .resource_exhausted => handleResourceError(info),
        .timeout => handleTimeoutError(info),
        .authentication => handleAuthError(info),
        else => handleGenericError(info),
    }
}

fn handleValidationError(info: otel_api.common.ErrorInfo) void {
    ErrorStats.incrementValidation();

    // Validation errors are development-time issues
    std.debug.print("🔍 VALIDATION: {s}.{s} - {s}\n", .{
        @tagName(info.component),
        info.operation,
        info.message,
    });

    if (info.context) |ctx| {
        std.debug.print("    Context: {s}\n", .{ctx});
    }

    // In a real application, you might:
    // - Log to a development metrics system
    // - Send alerts to developers
    // - Increment development quality metrics
}

fn handleNetworkError(info: otel_api.common.ErrorInfo) void {
    ErrorStats.incrementNetwork();

    std.debug.print("🌐 NETWORK: {s} failed - {s}\n", .{ info.operation, info.message });

    if (info.context) |ctx| {
        std.debug.print("    Endpoint: {s}\n", .{ctx});
    }

    // In a real application, you might:
    // - Implement retry logic
    // - Switch to backup endpoints
    // - Enable local buffering
    // - Alert operations team
}

fn handleResourceError(info: otel_api.common.ErrorInfo) void {
    ErrorStats.incrementResource();

    std.debug.print("💾 RESOURCE: {s} exhausted in {s}\n", .{ info.message, @tagName(info.component) });

    // In a real application, you might:
    // - Trigger garbage collection
    // - Reduce telemetry sampling rate
    // - Switch to memory-efficient modes
    // - Alert capacity planning team
}

fn handleTimeoutError(info: otel_api.common.ErrorInfo) void {
    std.debug.print("⏰ TIMEOUT: {s} timed out - {s}\n", .{ info.operation, info.message });

    // In a real application, you might:
    // - Adjust timeout settings
    // - Switch to async processing
    // - Alert performance monitoring
}

fn handleAuthError(info: otel_api.common.ErrorInfo) void {
    std.debug.print("🔐 AUTH: {s} authentication failed\n", .{info.operation});

    // In a real application, you might:
    // - Refresh authentication tokens
    // - Alert security team
    // - Switch to unauthenticated endpoints
}

fn handleGenericError(info: otel_api.common.ErrorInfo) void {
    std.debug.print("❌ ERROR: {s}.{s} - {s}\n", .{
        @tagName(info.component),
        info.operation,
        info.message,
    });

    if (info.source_error) |err| {
        std.debug.print("    Source: {}\n", .{err});
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("🚀 OpenTelemetry Error Handling Demo\n", .{});
    std.debug.print("====================================\n\n", .{});

    // Check what mode we're running in
    if (otel_api.common.isValidatingMode()) {
        std.debug.print("🐛 Running in DEBUG mode - validation enabled\n", .{});
    } else {
        std.debug.print("🚀 Running in RELEASE mode - validation disabled\n", .{});
    }

    // Set up custom error handler
    std.debug.print("📋 Setting up custom error handler...\n", .{});
    const original_handler = otel_api.common.getGlobalErrorHandler();
    defer otel_api.common.setGlobalErrorHandler(original_handler);
    otel_api.common.setGlobalErrorHandler(customErrorHandler);

    // Initialize OpenTelemetry with error-prone configuration
    std.debug.print("🔧 Setting up OpenTelemetry...\n", .{});
    const provider = setupOpenTelemetryWithErrors(init) catch |err| {
        std.debug.print("❌ Failed to setup OpenTelemetry: {}\n", .{err});
        return;
    };
    defer cleanupOpenTelemetry(provider);

    std.debug.print("\n📝 Running validation demonstrations...\n", .{});
    std.debug.print("==========================================\n", .{});

    // Demonstrate validation errors
    try demonstrateValidationErrors(allocator);

    std.debug.print("\n🔧 Running error handling demonstrations...\n", .{});
    std.debug.print("=============================================\n", .{});

    // Demonstrate different error types
    try demonstrateErrorTypes();

    std.debug.print("\n⚡ Running performance tests...\n", .{});
    std.debug.print("===============================\n", .{});

    // Measure performance impact
    try measurePerformanceImpact(init.io, allocator);

    std.debug.print("\n🏗️ Demonstrating error recovery patterns...\n", .{});
    std.debug.print("=============================================\n", .{});

    // Demonstrate error recovery
    try demonstrateErrorRecovery(allocator);

    // Print final statistics
    ErrorStats.printStats();
    std.debug.print("✅ Demo completed successfully!\n", .{});
}

fn setupOpenTelemetryWithErrors(init: std.process.Init) !*otel_sdk.trace.TracerProvider {
    // Set up OpenTelemetry with console export (less likely to fail than OTLP)
    return try otel_sdk.trace.setupGlobalProvider(
        init,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(.{ .io = init.io }))},
        null,
    );
}

fn cleanupOpenTelemetry(provider: *otel_sdk.trace.TracerProvider) void {
    provider.deinit();
    provider.destroy();
}

fn demonstrateValidationErrors(allocator: std.mem.Allocator) !void {
    const scope = otel_api.InstrumentationScope{ .name = "error-demo", .version = "1.0.0" };
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);

    const ctx = &[_]otel_api.ContextKeyValue{};

    std.debug.print("1. Testing span name validation:\n", .{});

    // Test empty span name (reported in debug mode)
    var span1 = tracer.startSpan("", .{}, ctx);
    defer span1.deinit();
    std.debug.print("   Created span with empty name\n", .{});

    // Test valid span name
    var span2 = tracer.startSpan("valid-operation", .{}, ctx);
    defer span2.deinit();
    std.debug.print("   Created span with valid name\n", .{});

    std.debug.print("\n2. Testing attribute validation:\n", .{});

    // Test empty attribute key (reported in debug mode)
    span2.setAttribute(.{ .key = "", .value = .{ .string = "invalid key" } });
    std.debug.print("   Set attribute with empty key\n", .{});

    // Test valid attribute
    span2.setAttribute(.{ .key = "valid.key", .value = .{ .string = "valid value" } });
    std.debug.print("   Set attribute with valid key\n", .{});

    std.debug.print("\n3. Testing batch attribute validation:\n", .{});

    const mixed_attributes = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "service.name", .value = .{ .string = "demo-service" } },
        .{ .key = "", .value = .{ .string = "empty key!" } }, // Invalid
        .{ .key = "service.version", .value = .{ .string = "1.0.0" } },
        .{ .key = "", .value = .{ .int = 42 } }, // Invalid
    };
    span2.setAttributes(&mixed_attributes);
    std.debug.print("   Set batch attributes with 2 invalid keys\n", .{});

    std.debug.print("\n4. Testing AttributeBuilder validation:\n", .{});

    var builder = otel_api.common.AttributeBuilder.init(allocator);
    builder = builder.add(.{ .key = "valid.key", .value = .{ .string = "ok" } });
    builder = builder.add(.{ .key = "", .value = .{ .string = "invalid!" } }); // Should make builder invalid in debug
    defer builder.deinit();

    const attrs = builder.finish(allocator) catch try allocator.alloc(otel_api.AttributeKeyValue, 0);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, attrs);
    std.debug.print("   Built attributes with invalid key, got {} final attributes\n", .{attrs.len});

    span1.end(null);
    span2.end(null);
}

fn demonstrateErrorTypes() !void {
    std.debug.print("1. Simulating network errors:\n", .{});

    // Simulate OTLP exporter network error
    otel_api.common.reportError(.{
        .component = .exporter,
        .operation = "OTLP export",
        .error_type = .network,
        .message = "Connection refused",
        .context = "http://localhost:4318/v1/traces",
    });

    // Simulate timeout error
    otel_api.common.reportError(.{
        .component = .exporter,
        .operation = "HTTP request",
        .error_type = .timeout,
        .message = "Request timeout after 30s",
        .context = "export_batch",
    });

    std.debug.print("\n2. Simulating resource errors:\n", .{});

    // Simulate memory exhaustion
    otel_api.common.reportError(.{
        .component = .processor,
        .operation = "span_processing",
        .error_type = .resource_exhausted,
        .message = "Failed to allocate span buffer",
        .source_error = error.OutOfMemory,
    });

    std.debug.print("\n3. Simulating authentication errors:\n", .{});

    // Simulate auth failure
    otel_api.common.reportError(.{
        .component = .exporter,
        .operation = "OTLP authenticate",
        .error_type = .authentication,
        .message = "Invalid API key",
        .context = "401 Unauthorized",
    });
}

fn measurePerformanceImpact(io: std.Io, allocator: std.mem.Allocator) !void {
    _ = allocator;
    const scope = otel_api.InstrumentationScope{ .name = "perf-test", .version = "1.0.0" };
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);

    const ctx = &.{};

    var span = tracer.startSpan("performance-test", .{}, ctx);
    defer span.deinit();

    const iterations = 10000;
    std.debug.print("Running {} setAttribute operations...\n", .{iterations});

    // Measure setAttribute performance
    const start_ts = std.Io.Clock.real.now(io);

    for (0..iterations) |i| {
        const key = if (i % 100 == 0) "" else "test.key"; // 1% invalid keys
        span.setAttribute(.{ .key = key, .value = .{ .int = @intCast(i) } });
    }

    const end_ts = std.Io.Clock.real.now(io);
    const duration_ns: i64 = @intCast(end_ts.nanoseconds - start_ts.nanoseconds);
    const ns_per_op = @divTrunc(duration_ns, iterations);

    std.debug.print("Performance results:\n", .{});
    std.debug.print("  Total time: {d:.2}ms\n", .{@as(f64, @floatFromInt(duration_ns)) / 1_000_000.0});
    std.debug.print("  Per operation: {d}ns\n", .{ns_per_op});

    if (otel_api.common.isValidatingMode()) {
        std.debug.print("  Mode: Debug (validation enabled)\n", .{});
        std.debug.print("  Expected ~{d}% validation errors\n", .{1});
    } else {
        std.debug.print("  Mode: Release (validation disabled)\n", .{});
        std.debug.print("  No validation overhead\n", .{});
    }

    span.end(null);
}

fn demonstrateErrorRecovery(allocator: std.mem.Allocator) !void {
    std.debug.print("1. Graceful AttributeBuilder recovery:\n", .{});

    // Demonstrate graceful recovery from builder errors
    var builder = otel_api.common.AttributeBuilder.init(allocator);
    builder = builder.add(.{ .key = "service.name", .value = .{ .string = "demo" } });
    builder = builder.add(.{ .key = "", .value = .{ .string = "this will fail in debug" } });
    builder = builder.add(.{ .key = "service.version", .value = .{ .string = "1.0.0" } });

    const result = builder.finish(allocator) catch try allocator.alloc(otel_api.AttributeKeyValue, 0);
    defer otel_api.common.AttributeKeyValue.deinitOwnedSlice(allocator, result);

    std.debug.print("   Attempted to build 3 attributes, got {} (graceful recovery)\n", .{result.len});

    std.debug.print("\n2. Defensive span creation:\n", .{});

    const scope = otel_api.InstrumentationScope{ .name = "recovery-test", .version = "1.0.0" };
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);

    const ctx = &[_]otel_api.ContextKeyValue{};

    // Defensive span creation with fallback
    const span_name = ""; // Problematic input

    var span = tracer.startSpan(span_name, .{}, ctx);
    defer span.deinit();
    std.debug.print("   Created span with invalid name ({s})\n", .{switch (span) {
        .bridge => |b| blk: {
            const ptr: *otel_sdk.trace.RecordingSpan = @ptrCast(@alignCast(b.span_ptr));
            break :blk ptr.name;
        },
        else => "--invalid span type for validation--",
    }});

    std.debug.print("\n3. Batch operation resilience:\n", .{});

    // Show that invalid attributes don't break batch operations
    const problematic_attrs = [_]otel_api.common.AttributeKeyValue{
        .{ .key = "good.attr1", .value = .{ .string = "value1" } },
        .{ .key = "", .value = .{ .string = "bad" } },
        .{ .key = "good.attr2", .value = .{ .int = 42 } },
        .{ .key = "", .value = .{ .bool = true } },
    };

    span.setAttributes(&problematic_attrs);
    std.debug.print("   Set {d} attributes with some invalid keys (operation completed)\n", .{problematic_attrs.len});
    std.debug.print("   Got {d} attributes when reading\n", .{switch (span) {
        .bridge => |b| blk: {
            const ptr: *otel_sdk.trace.RecordingSpan = @ptrCast(@alignCast(b.span_ptr));
            break :blk ptr.attributes.len;
        },
        else => 10000,
    }});

    span.end(null);

    std.debug.print("\n4. Error handler recovery:\n", .{});

    // Demonstrate that error handler failures don't crash the application
    const BadErrorHandler = struct {
        fn handle(info: otel_api.common.ErrorInfo, allocator_param: ?std.mem.Allocator) void {
            _ = info;
            _ = allocator_param;
            // Intentionally do something that might fail
            // In a real scenario, this could be network calls, file I/O, etc.
            // The system should remain stable even if error handlers fail
        }
    };

    const current_handler = otel_api.common.getGlobalErrorHandler();
    otel_api.common.setGlobalErrorHandler(BadErrorHandler.handle);

    // Generate an error that will be handled by the bad handler
    otel_api.common.reportValidationError(.tracer, "test", "Testing bad error handler", null);

    // Restore original handler
    otel_api.common.setGlobalErrorHandler(current_handler);
    std.debug.print("   Survived bad error handler (system remained stable)\n", .{});
}
