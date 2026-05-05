# Zig Otel

This is a zig implementation of the OTel API and SDK. It was built for zig 0.16.0.

## Build Commands

- `zig build` - Build and compile the libraries (otel-api, otel-sdk, otel-exporters, otel)
- `zig build install` - Install libraries to the standard install directory
- `zig build test` - Run all unit tests
- `zig build examples-install` - Build and install example executables
- `zig build examples` - Run all examples without installing
- `zig build example-<name>` - Run a specific example (e.g., `zig build example-simple-trace-sdk`)

For comprehensive testing, see individual test targets:
- `zig build test-api` - Run API tests only
- `zig build test-sdk` - Run SDK tests only
- `zig build test-exporters` - Run exporter tests only

## Quickstart

### Provider Setup
Providers are configured using the `setupGlobalProvider` pattern with pipeline configuration. The setup is consistent across all three signals (logs, metrics, traces) and involves configuring an exporter, processor, resource, and provider implementation.

The logging system supports integration with the existing `std.log`, in addition to otel API calls. This example shows both, using the OTLP exporter.

```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

// Clean up global providers at program exit
defer otel_api.provider_registry.unsetAllProviders();

// Setup global OTel logging provider with OTLP exporter
const provider = try otel_sdk.logs.setupGlobalProvider(
    allocator,
    .{otel_sdk.logs.SimpleLogRecordProcessor.PipelineStep.init({})
        .flowTo(otel_exporters.otlp.OtlpLogExporter.PipelineStep.init(.{}))},
);
defer {
    provider.deinit();
    provider.destroy();
}

// Only need this to Initialize the std.log bridge.
try otel_sdk.std_log_bridge.init(.{
    .enabled = true,
    .include_scope_attribute = true,
    .instrumentation_scope_name = "dns.query.std_log.example",
    .instrumentation_scope_version = "1.0.0",
});
defer otel_sdk.std_log_bridge.deinit();

// Now all std.log calls will automatically emit OpenTelemetry log records after the above.
std.log.info("This is really an OTel log.", .{});

// normal otel calls still work too.
const logger_scope = otel_api.InstrumentationScope{ .name = "multiply", .version = "1.0.0" };
var logger = try logger_provider.getLoggerWithScope(logger_scope);
logger.emitLog(
    &.{}, // context
    .info, // log level
    "HTTP server thread started", // log message
    &[_]otel_api.common.AttributeKeyValue{ // attributes.
        .{ .key = "address", .value = .{ .string = shared_state.server_address } },
        .{ .key = "port", .value = .{ .int = @intCast(shared_state.server_port) } },
    },
    null, // event_name
);
```

Metrics setup is very similar, although it doesn't currently support any other integrations.

```zig
// Metrics setup
const concrete_provider = try otel_sdk.metrics.setupGlobalProvider(
    allocator,
    .{otel_sdk.metrics.ManualReader.PipelineStep.init({})
        .flowTo(otel_exporters.otlp.OtlpMetricExporter.PipelineStep.init(.{}))},
);
defer {
    concrete_provider.deinit();
    concrete_provider.destroy();
}

// Get a meter
const scope = otel_api.InstrumentationScope{ .name = "example.metric.otlp", .version = "1.0.0" };
var meter = try otel_api.getGlobalMeterProvider().getMeterWithScope(scope);
```

Traces is similar to metrics. This example uses the stream exporter to output to stderr.

```zig
    // Set up trace provider using the new setupGlobalProvider pattern
    var stderr_buffer = [_]u8{0} ** 1024;
    var stderr = otel_exporters.console.initStream(true, &stderr_buffer);
    const concrete_provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.stream.SpanDataSink.PipelineStep.init(.{
            .writer = &stderr.interface,
            .flush_after_each = true,
        }))},
    );
    defer {
        concrete_provider.deinit();
        concrete_provider.destroy();
    }

    // Get the global tracer provider interface
    var tp = otel_api.getGlobalTracerProvider();

    // Get a tracer
    const scope = otel_api.InstrumentationScope{ .name = "example-component", .version = "1.0.0" };
    var tracer = try tp.getTracerWithScope(scope);

    // Create a root context
    const ctx = &[_]otel_api.ContextKeyValue{};

    // Start a parent span
    const parent_result = tracer.startSpan("parent-operation", .{
        .kind = .server,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{
                .key = "http.method",
                .value = otel_api.common.AttributeValue{ .string = "GET" },
            },
            .{
                .key = "http.url",
                .value = otel_api.common.AttributeValue{ .string = "/api/example" },
            },
        },
    }, ctx);
    defer {
        parent_result.end(null);
        parent_result.deinit();
    }
    // do stuff before the span is ended.
```

These examples show the setup of the SDK, but most usages should focus on the APIs exposed from `otel_api.getGlobalTracerProvider()` and similar methods.

### Multiple Exporters

Pass multiple pipeline steps in the tuple to fan out to more than one exporter. Each step registers an independent processor, so every span (or log/metric) is delivered to all exporters. This is useful for sending to OTLP in production while also streaming to console during development.

```zig
var stderr_buffer = [_]u8{0} ** 1024;
var stderr_stream = otel_exporters.console.initStream(true, &stderr_buffer);

const trace_provider = try otel_sdk.trace.setupGlobalProvider(
    allocator,
    .{
        // Production exporter
        otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(.{})),
        // Debug exporter (runs alongside, independently)
        otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.stream.SpanDataSink.PipelineStep.init(.{
                .writer = &stderr_stream.interface,
                .flush_after_each = true,
            })),
    },
);
defer {
    trace_provider.deinit();
    trace_provider.destroy();
}
```

The same pattern applies to logs (two `SimpleLogRecordProcessor` steps) and metrics (two reader steps).

## The API

The API part provides methods for getting and setting Global Providers and the necessary interfaces for using them.

## The SDK

The SDK is structed with subdirectories for `logs`, `metrics`, and `traces`, but they all follow the same general architecture pattern:

```
                    ┌─────────────────┐
                    │   api.Provider  │ (interface)
                    └─────────────────┘
                             △
                             │ implements
                             │
                    ┌─────────────────┐
                    │sdk.StandardProvider│
                    └─────────────────┘
                             │
                             │ uses
                             │
                             ▼
                    ┌─────────────────┐
                    │  sdk.Processor  │ (interface)
                    └─────────────────┘
                             △
                             │ implements
                             │
                    ┌─────────────────┐
                    │sdk.SimpleProcessor│
                    └─────────────────┘
                             │
                             │ uses
                             │
                             ▼
                    ┌─────────────────┐
                    │  sdk.Exporter   │ (interface)
                    └─────────────────┘
                             △
                             │ implements
                             │
                    ┌─────────────────┐
                    │   exporters     │ (module)
                    │   - Console     │
                    │   - OTLP        │
                    │   - etc.        │
                    └─────────────────┘
```

The flow is: Provider → Processor/Reader → Exporter, with each component being responsible for a specific part of the telemetry pipeline.

## Limitations

- **No std.http integration** -- W3C trace context propagation (traceparent/tracestate) is fully implemented, but there is no automatic middleware for injecting/extracting headers from `std.http` requests. See [`examples/multithreaded_http_telemetry.zig`](examples/multithreaded_http_telemetry.zig) for a manual example.
- **A couple of things diverge from the specification** -- That is taken from [a thread from nodejs about OTel](https://github.com/nodejs/node/issues/57992#issuecomment-2844248550). In summary, the spec is to make it easy to rationalize, but it is not the only way to implement the model.
- **Depends on protobuf** -- This sdk depends on [Arwalk's zig-protobuf](https://github.com/Arwalk/zig-protobuf/) for the exporter. Luckily they've recently done a bunch of zig 0.15 upgrades as well.
