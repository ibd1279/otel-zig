const std = @import("std");
const api = @import("otel-api");
const sdk = struct {
    const MeterProvider = @import("meter_provider.zig").MeterProvider;
    const detectResource = @import("../resource/detector.zig").detectResource;
};

const DefaultProvider = sdk.MeterProvider;

/// Create a default provider value with automatically detected resources.
/// Returns provider by value - used internally by setupGlobalProvider.
fn createDefaultProviderValue(allocator: std.mem.Allocator, io: std.Io) !DefaultProvider {
    // Step 1: Detect resource
    const detected_resource = try sdk.detectResource(allocator);
    errdefer detected_resource.deinitOwned(allocator);

    // Step 3: Create provider
    return .init(
        allocator,
        io,
        detected_resource,
    );
}

/// Setup a global meter provider with pipeline configuration (backward compatibility).
/// Creates a heap-allocated provider, configures the pipeline using the provided links,
/// registers it with the global registry, and returns the concrete provider pointer.
/// The caller is responsible for calling deinit() and destroy() on the returned provider.
pub fn setupGlobalProvider(init: std.process.Init, links: anytype) !*DefaultProvider {
    return setupGlobalProviderWithViews(init, links, .{});
}

/// Setup a global meter provider with pipeline configuration and views.
/// Creates a heap-allocated provider, configures the pipeline using the provided links,
/// registers views, registers it with the global registry, and returns the concrete provider pointer.
/// The caller is responsible for calling deinit() and destroy() on the returned provider.
pub fn setupGlobalProviderWithViews(init: std.process.Init, links: anytype, views: anytype) !*DefaultProvider {
    const allocator = init.gpa;
    // 1. Create heap-allocated concrete provider
    const provider_ptr = try allocator.create(DefaultProvider);
    errdefer allocator.destroy(provider_ptr);

    provider_ptr.* = try createDefaultProviderValue(allocator, init.io);
    errdefer provider_ptr.deinit();

    // 2. Register views before pipeline setup
    inline for (views) |view| {
        try provider_ptr.addView(view);
    }

    // 3. Configure pipeline using the links tuple
    var builder = provider_ptr.pipelineBuilder();
    inline for (links) |link| {
        builder = builder.with(link);
    }
    try builder.done();

    // 4. Register with global registry (it handles interface wrapper memory management)
    try api.provider_registry.setGlobalMeterProvider(provider_ptr.meterProvider());

    // 5. Return concrete provider pointer for caller management
    return provider_ptr;
}
