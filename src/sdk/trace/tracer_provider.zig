//! OpenTelemetry SDK Tracer Provider Implementation
//!
//! This module provides the concrete implementation of the TracerProvider interface
//! for the SDK. TracerProvider manages tracers and their lifecycle.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
    const common = struct {
        const InstrumentationScopeMapContext = @import("../common/scope_context.zig").InstrumentationScopeMapContext;
        const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
        const Timeout = @import("../common/timeout.zig");
    };
    const trace = struct {
        const IdGenerator = @import("id_generator.zig").IdGenerator;
        const SpanDataProcessor = @import("processor.zig").SpanProcessor;
        const Tracer = @import("tracer.zig").StandardTracer;
        const samplers = @import("samplers/root.zig");
        const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
    };
};

/// Basic implementation of the TracerProvider interface
pub const TracerProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: sdk.Resource,
    cache: std.HashMapUnmanaged(api.InstrumentationScope, *sdk.trace.Tracer, sdk.common.InstrumentationScopeMapContext, 80),
    processors: std.ArrayListUnmanaged(sdk.trace.SpanDataProcessor),
    id_generator: sdk.trace.IdGenerator,
    sampler: api.trace.Sampler,
    span_limits: api.trace.Span.Limits,
    mutex: std.Io.Mutex,
    is_shutdown: std.atomic.Value(bool),

    /// Create a new basic tracer provider
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        resource: sdk.Resource,
        id_generator: sdk.trace.IdGenerator,
        sampler: api.trace.Sampler,
    ) TracerProvider {
        return .{
            .allocator = allocator,
            .io = io,
            .resource = resource,
            .cache = .empty,
            .processors = .empty,
            .id_generator = id_generator,
            .sampler = sampler,
            .span_limits = api.trace.Span.Limits.default,
            .mutex = std.Io.Mutex.init,
            .is_shutdown = .init(false),
        };
    }

    /// Clean up provider resources
    pub fn deinit(self: *TracerProvider) void {
        _ = self.shutdown(null);

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                kv.key_ptr.deinitOwned(self.allocator);
                kv.value_ptr.*.deinit();
                self.allocator.destroy(kv.value_ptr.*);
            }
            self.cache.deinit(self.allocator);

            for (self.processors.items) |processor| {
                processor.deinit();
                processor.destroy();
            }
            self.processors.deinit(self.allocator);
        }

        self.resource.deinitOwned(self.allocator);
    }

    pub fn destroy(self: *TracerProvider) void {
        self.allocator.destroy(self);
    }

    /// Shutdown the provider with optional timeout
    pub fn shutdown(self: *TracerProvider, timeout_ms: ?u64) api.common.ProcessResult {
        if (self.is_shutdown.load(.monotonic)) return .success;

        const timeout = sdk.common.Timeout.init(self.io, timeout_ms);

        // The mutex block is distinct because the mutex must be released before
        // forceFlush can be called.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // Flag each tracer as shutdown to stop collection and instrument creation
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                if (timeout.isExpired()) return .timeout;
                kv.value_ptr.*.shutdown();
            }
        }

        const result = self.forceFlush(timeout.remaining() catch return .timeout).asProcessResult();
        if (result.isSuccess()) self.is_shutdown.store(true, .monotonic);
        return result;
    }

    pub fn forceFlush(self: *TracerProvider, timeout_ms: ?u64) api.common.FlushResult {
        // Shutdown providers can still force flush. No shutdown check.

        const timeout = sdk.common.Timeout.init(self.io, timeout_ms);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.processors.items) |*processor| {
            const flush_result = processor.forceFlush(timeout.remaining() catch return .timeout);
            switch (flush_result) {
                .success => {},
                else => return flush_result,
            }
        }
        return .success;
    }

    // TracerProvider interface implementation
    //
    // Returns a noop tracer and reports to the OTel error handler if allocation fails.
    pub fn getTracerWithScope(self: *TracerProvider, scope: api.InstrumentationScope) api.trace.Tracer {
        // Short circuit if the provider is shutdown.
        if (self.is_shutdown.load(.monotonic)) return .{ .noop = {} };

        return self.getTracerWithScopeInternal(scope) catch |err| {
            api.common.reportResourceExhaustedErrorWithSource(
                .tracer,
                "getTracerWithScope",
                "Failed to allocate tracer for instrumentation scope; returning noop",
                null,
                err,
            );
            return api.trace.Tracer{ .noop = {} };
        };
    }

    fn getTracerWithScopeInternal(self: *TracerProvider, scope: api.InstrumentationScope) !api.trace.Tracer {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Return the existing tracer if it exists. Requires mutex for map scan.
        if (self.cache.get(scope)) |tracer| {
            return tracer.tracer();
        }

        // Create the missing key value for the cache.
        const owned_scope = try api.InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        const new_tracer = try self.allocator.create(sdk.trace.Tracer);
        errdefer self.allocator.destroy(new_tracer);
        new_tracer.* = sdk.trace.Tracer.init(
            self,
            owned_scope,
        );

        try self.cache.put(self.allocator, owned_scope, new_tracer);

        return new_tracer.tracer();
    }

    /// Register a processor with this provider.
    ///
    /// This method is not thread-safe and should only be called during initialization.
    pub fn registerProcessor(self: *TracerProvider, processor: sdk.trace.SpanDataProcessor) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.processors.append(self.allocator, processor);
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *TracerProvider) sdk.common.PipelineBuilder(*TracerProvider) {
        return .init(self);
    }

    /// Create a TracerProvider interface for this basic provider
    pub fn tracerProvider(self: *TracerProvider) api.trace.TracerProvider {
        return .{ .bridge = .init(self) };
    }
};

test "TracerProvider basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const resource = sdk.Resource{
        .attributes = &.{},
        .schema_url = null,
    };

    const processor = sdk.trace.SpanDataProcessor{ .noop = {} };

    var provider_ptr = TracerProvider.init(
        allocator,
        std.testing.io,
        resource,
        try sdk.trace.createDefaultIdGenerator(std.testing.io),
        sdk.trace.samplers.always_on,
    );
    try provider_ptr.registerProcessor(processor);
    defer provider_ptr.deinit();

    var tp = provider_ptr.tracerProvider();

    // Get a tracer
    const tracer1 = tp.getTracerWithScope(.{
        .name = "test-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });
    _ = tracer1;

    // Get the same tracer again (should be cached)
    const tracer2 = tp.getTracerWithScope(.{
        .name = "test-tracer",
        .version = null,
        .schema_url = null,
        .attributes = &.{},
    });
    _ = tracer2;

    // Force flush
    try testing.expectEqual(api.common.FlushResult.success, provider_ptr.forceFlush(null));
}
