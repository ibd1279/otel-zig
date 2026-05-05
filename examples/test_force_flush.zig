//! Test Enhanced forceFlush Functionality
//!
//! This example demonstrates the enhanced forceFlush implementation that
//! performs immediate collection/export with proper synchronization.

const std = @import("std");
const otel_api = @import("otel-api");
const otel_sdk = @import("otel-sdk");
const otel_exporters = @import("otel-exporters");

var program_start_ns: i96 = 0;

// Custom exporter to track flush and export calls
const TrackingExporter = struct {
    pub const PipelineStep = otel_sdk.common.PipelineStepInstructions(
        TrackingExporter,
        otel_sdk.trace.SpanExporter,
        std.Io,
        spanExporter,
        _init,
        otel_sdk.common.PipelineDeinitConnection,
    );

    pub fn _init(self: *TrackingExporter, ctx: std.Io, allocator: std.mem.Allocator) !void {
        self.* = init(allocator, ctx);
    }

    allocator: std.mem.Allocator,
    io: std.Io,
    export_count: std.atomic.Value(u32),
    flush_count: std.atomic.Value(u32),
    last_export_time: std.atomic.Value(i64),
    last_flush_time: std.atomic.Value(i64),

    // Global instance for tracking stats
    var global_export_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    var global_flush_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    var global_last_export_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
    var global_last_flush_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

    pub fn init(allocator: std.mem.Allocator, io: std.Io) TrackingExporter {
        return .{
            .allocator = allocator,
            .io = io,
            .export_count = std.atomic.Value(u32).init(0),
            .flush_count = std.atomic.Value(u32).init(0),
            .last_export_time = std.atomic.Value(i64).init(0),
            .last_flush_time = std.atomic.Value(i64).init(0),
        };
    }

    pub fn deinit(self: *TrackingExporter) void {
        _ = self;
    }

    pub fn destroy(self: *TrackingExporter) void {
        self.allocator.destroy(self);
    }

    pub fn exportSpans(self: *TrackingExporter, spans: []const otel_sdk.trace.SpanData, resource: otel_sdk.resource.Resource) otel_api.common.ExportResult {
        _ = resource;
        _ = self.export_count.fetchAdd(1, .monotonic);
        _ = global_export_count.fetchAdd(1, .monotonic);
        const current_time: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds - program_start_ns, std.time.ns_per_ms));
        self.last_export_time.store(current_time, .release);
        global_last_export_time.store(current_time, .release);

        std.debug.print("[EXPORTER] Exporting {} spans at time {}ms\n", .{ spans.len, current_time });

        // Simulate some export work
        std.Io.sleep(self.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
        return .success;
    }

    pub fn forceFlush(self: *TrackingExporter, timeout_ms: ?u64) otel_api.common.ExportResult {
        _ = timeout_ms;
        _ = self.flush_count.fetchAdd(1, .monotonic);
        _ = global_flush_count.fetchAdd(1, .monotonic);
        const current_time: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds - program_start_ns, std.time.ns_per_ms));
        self.last_flush_time.store(current_time, .release);
        global_last_flush_time.store(current_time, .release);

        std.debug.print("[EXPORTER] ForceFlush called at time {}ms\n", .{current_time});

        return .success;
    }

    pub fn shutdown(_: *TrackingExporter, timeout_ms: ?u64) otel_api.common.ExportResult {
        _ = timeout_ms;
        std.debug.print("[EXPORTER] Shutdown called\n", .{});
        return .success;
    }

    pub fn spanExporter(self: *TrackingExporter) otel_sdk.trace.SpanExporter {
        return otel_sdk.trace.SpanExporter{ .bridge = otel_sdk.trace.BridgeSpanExporter.init(self) };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    program_start_ns = std.Io.Clock.real.now(io).nanoseconds;
    std.debug.print("\n=== Testing Enhanced forceFlush ===\n\n", .{});

    // Setup batch processor with tracking exporter
    const concrete_provider = try otel_sdk.trace.setupGlobalProvider(
        init,
        .{otel_sdk.trace.BatchSpanProcessor.PipelineStep.init(.{
            .io = io,
            .export_interval_ms = 5000, // 5 second interval
            .max_queue_size = 100,
        }).flowTo(TrackingExporter.PipelineStep.init(io))},
        null,
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get a tracer
    const scope = otel_api.InstrumentationScope{ .name = "force_flush_test", .version = "1.0.0" };
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);

    const start_time: i64 = 0; // relative to program_start

    // Create some spans
    std.debug.print("Creating spans...\n", .{});
    for (0..5) |i| {
        var span = tracer.startSpan("test-span", .{
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "index", .value = .{ .int = @intCast(i) } },
            },
        }, &.{});
        span.end(null);
        span.deinit();
        std.debug.print("  Created span {}\n", .{i});
        try std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake);
    }

    const after_spans_time: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds - program_start_ns, std.time.ns_per_ms));
    std.debug.print("\nTime after creating spans: {} ms from start\n", .{after_spans_time - start_time});

    // Test 1: Force flush should trigger immediate export
    std.debug.print("\n[TEST 1] Calling forceFlush - should trigger immediate export\n", .{});
    const flush_start: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds - program_start_ns, std.time.ns_per_ms));
    const flush_result = concrete_provider.forceFlush(2000);
    const flush_end: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds - program_start_ns, std.time.ns_per_ms));

    std.debug.print("ForceFlush result: {}\n", .{flush_result});
    std.debug.print("ForceFlush took {} ms\n", .{flush_end - flush_start});

    const export_count_1 = TrackingExporter.global_export_count.load(.acquire);
    const flush_count_1 = TrackingExporter.global_flush_count.load(.acquire);
    std.debug.print("Export count after flush: {}\n", .{export_count_1});
    std.debug.print("Flush count after flush: {}\n", .{flush_count_1});

    // Test 2: Create more spans and flush again
    std.debug.print("\n[TEST 2] Creating more spans and flushing again\n", .{});
    for (5..8) |i| {
        var span = tracer.startSpan("test-span-2", .{
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "index", .value = .{ .int = @intCast(i) } },
            },
        }, &.{});
        span.end(null);
        span.deinit();
    }

    const flush_result_2 = concrete_provider.forceFlush(2000);
    std.debug.print("Second flush result: {}\n", .{flush_result_2});

    const export_count_2 = TrackingExporter.global_export_count.load(.acquire);
    const flush_count_2 = TrackingExporter.global_flush_count.load(.acquire);
    std.debug.print("Export count after second flush: {}\n", .{export_count_2});
    std.debug.print("Flush count after second flush: {}\n", .{flush_count_2});

    // Test 3: Concurrent flush calls
    std.debug.print("\n[TEST 3] Testing concurrent flush calls\n", .{});

    // Create a thread that will call flush
    const FlushThread = struct {
        fn run(provider: *otel_sdk.trace.TracerProvider) void {
            std.debug.print("  [Thread] Starting flush...\n", .{});
            const result = provider.forceFlush(3000);
            std.debug.print("  [Thread] Flush complete: {}\n", .{result});
        }
    };

    const thread = try std.Thread.spawn(.{}, FlushThread.run, .{concrete_provider});

    // Give thread time to start
    try std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

    // Try to flush from main thread too
    std.debug.print("  [Main] Starting flush...\n", .{});
    const concurrent_result = concrete_provider.forceFlush(3000);
    std.debug.print("  [Main] Flush complete: {}\n", .{concurrent_result});

    thread.join();

    // Test 4: Flush with timeout
    std.debug.print("\n[TEST 4] Testing flush with very short timeout\n", .{});

    // Create many spans to make export take longer
    for (0..20) |i| {
        var span = tracer.startSpan("bulk-span", .{
            .attributes = &[_]otel_api.common.AttributeKeyValue{
                .{ .key = "bulk_index", .value = .{ .int = @intCast(i) } },
            },
        }, &.{});
        span.end(null);
        span.deinit();
    }

    // Try flush with 1ms timeout (should timeout)
    const timeout_result = concrete_provider.forceFlush(1);
    std.debug.print("Flush with 1ms timeout result: {}\n", .{timeout_result});

    // Give time for background export to complete
    try std.Io.sleep(io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake);

    // Final stats
    std.debug.print("\n=== Final Statistics ===\n", .{});
    std.debug.print("Total exports: {}\n", .{TrackingExporter.global_export_count.load(.acquire)});
    std.debug.print("Total flushes: {}\n", .{TrackingExporter.global_flush_count.load(.acquire)});
    std.debug.print("Last export time: {}\n", .{TrackingExporter.global_last_export_time.load(.acquire)});
    std.debug.print("Last flush time: {}\n", .{TrackingExporter.global_last_flush_time.load(.acquire)});

    std.debug.print("\n=== Test Complete ===\n", .{});
}
