const std = @import("std");
const trace_api = @import("otel-api").trace;
const provider_registry = @import("otel-api").provider_registry;

const trace_provider = @import("tracer_provider.zig");
const detectResource = @import("../resource/detector.zig").detectResource;
const Resource = @import("../resource/resource.zig").Resource;

const createDefaultIdGenerator = @import("id_generator.zig").createDefaultIdGenerator;
const samplers = @import("samplers/root.zig");

const DefaultProvider = trace_provider.TracerProvider;

/// Create a default provider value with automatically detected resources.
/// Returns provider by value - used internally by setupGlobalProvider.
fn createDefaultProviderValue(allocator: std.mem.Allocator, io: std.Io, application_resource: ?Resource) !DefaultProvider {
    // Step 1: Detect resource
    var detected_resource = try detectResource(allocator, io);
    errdefer detected_resource.deinitOwned(allocator);

    // Step 2: Merge application resource if provided (application attrs win on duplicates)
    if (application_resource) |app_res| {
        const merged = try Resource.initOwnedMerge(allocator, detected_resource, app_res);
        detected_resource.deinitOwned(allocator);
        detected_resource = merged;
    }

    // Step 3: Create provider
    return DefaultProvider.init(
        allocator,
        io,
        detected_resource,
        createDefaultIdGenerator(),
        samplers.always_on,
    );
}

/// Setup a global tracer provider with pipeline configuration.
/// Creates a heap-allocated provider, configures the pipeline using the provided links,
/// registers it with the global registry, and returns the concrete provider pointer.
/// The caller is responsible for calling deinit() and destroy() on the returned provider.
pub fn setupGlobalProvider(init: std.process.Init, links: anytype, application_resource: ?Resource) !*DefaultProvider {
    const allocator = init.gpa;
    // 1. Create heap-allocated concrete provider
    const provider_ptr = try allocator.create(DefaultProvider);
    errdefer allocator.destroy(provider_ptr);

    provider_ptr.* = try createDefaultProviderValue(allocator, init.io, application_resource);
    errdefer provider_ptr.deinit();

    // 2. Configure pipeline using the links tuple
    var builder = provider_ptr.pipelineBuilder();
    inline for (links) |link| {
        builder = builder.with(link);
    }
    try builder.done();

    // 3. Register with global registry (it handles interface wrapper memory management)
    try provider_registry.setGlobalTracerProvider(provider_ptr.tracerProvider());

    // 4. Return concrete provider pointer for caller management
    return provider_ptr;
}
