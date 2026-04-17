//! OpenTelemetry SDK Standard Tracer Implementation
//!
//! This module provides the concrete implementation of the Tracer interface
//! for the SDK. StandardTracer creates spans and manages their lifecycle.

const std = @import("std");
const otel_api = @import("otel-api");

const sdk = struct {
    const trace = struct {
        const RecordingSpan = @import("data.zig").RecordingSpan;
        const SpanData = @import("data.zig").SpanData;
        const TracerProvider = @import("tracer_provider.zig").TracerProvider;
    };
};

/// Standard implementation of the Tracer interface
pub const StandardTracer = struct {
    provider: *sdk.trace.TracerProvider, // non-owning
    scope: otel_api.InstrumentationScope, // non-owning
    is_shutdown: std.atomic.Value(bool),

    /// Create a new standard tracer
    pub fn init(
        provider: *sdk.trace.TracerProvider,
        scope: otel_api.InstrumentationScope,
    ) StandardTracer {
        return .{
            .provider = provider,
            .scope = scope,
            .is_shutdown = .init(false),
        };
    }

    pub fn deinit(self: *StandardTracer) void {
        _ = self;
    }

    pub fn shutdown(self: *StandardTracer) void {
        self.is_shutdown.store(true, .monotonic);
    }

    // Tracer interface implementation

    pub fn startSpan(
        self: *StandardTracer,
        name: []const u8,
        options: ?otel_api.trace.Span.StartOptions,
        ctx: []const otel_api.ContextKeyValue,
    ) !otel_api.trace.Span {
        if (self.is_shutdown.load(.monotonic)) return otel_api.trace.Span{ .noop = .invalid };

        // Get options or use defaults
        const opts = options orelse otel_api.trace.Span.StartOptions.default;

        // Validate span name in debug mode
        if (!otel_api.trace.validateSpanName(name)) {
            otel_api.common.reportValidationError(.tracer, "startSpan", "Empty span name provided", null);
        }

        // Get timestamp
        const default_ts = std.Io.Clock.real.now(self.provider.io);
        const start_time = opts.start_time orelse default_ts;

        // Extract parent context if present
        const parent_span_context = otel_api.trace.trace_context.getSpanContext(ctx);

        // Generate IDs
        var trace_id: otel_api.common.TraceId = undefined;
        var span_id: otel_api.common.SpanId = undefined;

        if (parent_span_context) |parent| {
            // Use parent's trace ID
            trace_id = parent.trace_id;
            span_id = otel_api.common.SpanId.fromBytes(self.provider.id_generator.generateSpanId());
        } else {
            // Generate new trace ID
            trace_id = otel_api.common.TraceId.fromBytes(self.provider.id_generator.generateTraceId());
            span_id = otel_api.common.SpanId.fromBytes(self.provider.id_generator.generateSpanId());
        }

        // Extract links from options
        const links = opts.links;

        // Extract attributes from options
        const attributes = opts.attributes;

        // Create sample parameters for sampling decision
        const sample_params = otel_api.trace.Sampler.Params{
            .allocator = self.provider.allocator,
            .context = ctx,
            .trace_id = trace_id,
            .span_name = name,
            .span_kind = opts.kind,
            .attributes = attributes,
            .links = links,
            .parent_ctx = parent_span_context,
        };

        // Get sampling decision
        const sampling_result = self.provider.sampler.shouldSample(sample_params);

        // Determine trace flags based on sampling decision
        const trace_flags: u8 = switch (sampling_result.decision) {
            .drop => 0,
            .record_only => 0,
            .record_and_sample => otel_api.trace.Span.Context.SAMPLED_FLAG,
        };

        // Handle sampling decision
        switch (sampling_result.decision) {
            .drop => {
                // Dropped spans are non-recording; trace_state is unused
                return otel_api.trace.Span{ .noop = .{
                    .trace_id = trace_id,
                    .span_id = span_id,
                    .trace_flags = trace_flags,
                    .trace_state = null,
                    .is_remote = false,
                } };
            },
            .record_only, .record_and_sample => {
                const span_context = otel_api.trace.Span.Context{
                    .trace_id = trace_id,
                    .span_id = span_id,
                    .trace_flags = trace_flags,
                    .trace_state = if (sampling_result.trace_state) |ts| try self.provider.allocator.dupe(u8, ts) else null,
                    .is_remote = false,
                };
                errdefer span_context.deinit(self.provider.allocator);

                const recording = try self.provider.allocator.create(sdk.trace.RecordingSpan);
                recording.* = try sdk.trace.RecordingSpan.init(self, name);

                // Add links from StartOptions to the recording span
                if (links.len > 0) {
                    try recording.addLinks(links);
                }

                // Add attributes from StartOptions to the recording span
                if (attributes.len > 0) {
                    recording.setAttributes(attributes);
                }

                const bridge = otel_api.trace.Span.Bridge.init(
                    recording,
                    span_context,
                    parent_span_context,
                    opts.kind,
                    start_time,
                    null, // end_time — set on end()
                    true,
                    self.provider.allocator,
                );
                var span = otel_api.trace.Span{ .bridge = bridge };
                span.setStatus(opts.status);
                return span;
            },
        }
    }

    pub fn enabled(self: *StandardTracer) bool {
        return !self.is_shutdown.load(.monotonic);
    }

    /// Create a Tracer interface for this standard tracer
    pub inline fn tracer(self: *StandardTracer) otel_api.trace.Tracer {
        return .{ .bridge = .init(self) };
    }
};
