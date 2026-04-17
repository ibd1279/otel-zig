//! OpenTelemetry SDK Meter Provider Implementation
//!
//! This module provides the concrete implementation of the MeterProvider interface
//! for the SDK. MeterProvider manages meters and their lifecycle.

const std = @import("std");
const api = @import("otel-api");

const sdk = struct {
    const Resource = @import("../resource/resource.zig").Resource;
    const common = struct {
        const InstrumentationScopeMapContext = @import("../common/scope_context.zig").InstrumentationScopeMapContext;
        const PipelineBuilder = @import("../common/pipeline.zig").PipelineBuilder;
        const Timeout = @import("../common/timeout.zig");
    };
    const logs = struct {
        const LogRecordProcessor = @import("processor.zig").LogRecordProcessor;
        const Logger = @import("logger.zig").Logger;
    };
};

/// Basic logger provider with caching
pub const LoggerProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: sdk.Resource,
    cache: std.HashMapUnmanaged(api.InstrumentationScope, *sdk.logs.Logger, sdk.common.InstrumentationScopeMapContext, 80),
    processors: std.ArrayListUnmanaged(sdk.logs.LogRecordProcessor),
    mutex: std.Io.Mutex,
    is_shutdown: std.atomic.Value(bool),
    default_min_severity: api.logs.Severity,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        resource: sdk.Resource,
    ) LoggerProvider {
        return .{
            .allocator = allocator,
            .io = io,
            .resource = resource,
            .cache = .empty,
            .processors = .empty,
            .mutex = std.Io.Mutex.init,
            .is_shutdown = .init(false),
            .default_min_severity = if (@import("builtin").mode == .Debug) .debug else .warn,
        };
    }

    pub fn deinit(self: *LoggerProvider) void {
        _ = self.shutdown(null);

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

        self.resource.deinitOwned(self.allocator);
    }

    pub fn destroy(self: *LoggerProvider) void {
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *LoggerProvider, timeout_ms: ?u64) api.common.ProcessResult {
        if (self.is_shutdown.load(.monotonic)) return .success;

        const timeout = sdk.common.Timeout.init(timeout_ms);

        // The mutex block is distinct because the mutex must be released before
        // forceFlush can be called.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // flag each logger as shutdown to stop collection.
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

    /// Interface defined method to force the attached processor to flush.
    pub fn forceFlush(self: *LoggerProvider, timeout_ms: ?u64) api.common.FlushResult {
        // Shutdown providers can still force flush. No shutdown check.

        const timeout = sdk.common.Timeout.init(timeout_ms);

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

    /// Interface definde method to get a logger.
    pub fn getLoggerWithScope(self: *LoggerProvider, scope: api.InstrumentationScope) !api.logs.Logger {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Check cache first
        if (self.cache.get(scope)) |logger| {
            // Already created, so return the type erased interface.
            return logger.logger();
        }

        // Create a locally owned Scope.
        const owned_scope = try api.InstrumentationScope.initOwned(self.allocator, scope);
        errdefer owned_scope.deinitOwned(self.allocator);

        // Create new SDK logger
        const sdk_logger = try self.allocator.create(sdk.logs.Logger);
        errdefer self.allocator.destroy(sdk_logger);

        // TODO: Why is the invalid hard-coded here? Should come from config.
        sdk_logger.* = sdk.logs.Logger.init(self, owned_scope, self.default_min_severity);

        // Cache the resulting logger for this scope.
        try self.cache.put(self.allocator, owned_scope, sdk_logger);

        // Return the type erased interface.
        return sdk_logger.logger();
    }

    /// Attach a processor to this provider.
    ///
    /// This method is not thread-safe and should only be called during initialization.
    pub fn registerProcessor(self: *LoggerProvider, processor: sdk.logs.LogRecordProcessor) !void {
        try self.processors.append(self.allocator, processor);
    }

    /// Convert the provider into an API interface.
    pub fn loggerProvider(self: *LoggerProvider) api.logs.LoggerProvider {
        return api.logs.LoggerProvider{ .bridge = api.logs.LoggerProviderBridge.init(self) };
    }

    /// Generate a pipelinebuilder for this provider.
    pub fn pipelineBuilder(self: *LoggerProvider) sdk.common.PipelineBuilder(*LoggerProvider) {
        return .init(self);
    }
};
