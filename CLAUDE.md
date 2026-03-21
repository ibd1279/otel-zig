# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Versions

The code targets zig version 0.15.1. This often means you should ask the human what the current way to do things is. For example, *Io.Writers, ArrayList, and the Http library all had large refactors in the upgrade to 0.15, which was after your training data set.

## Build Commands

- `zig build` - Build and compile all libraries (otel-api, otel-sdk, otel-exporters, otel)
- `zig build install` - Install libraries to the standard install directory
- `zig build test` - Run all unit tests
- `zig build test-api` - Run API-only tests
- `zig build test-sdk` - Run SDK-only tests
- `zig build test-exporters` - Run exporter tests
- `zig build examples` - Run all examples without installing
- `zig build examples-install` - Build and install example executables
- `zig build example-<name>` - Run a specific example (e.g., `zig build example-multithreaded-http`)
- `zig build --verbose example-multithreaded-http -- console 20 1.0` - run a comprehensive test for 20 seconds outputting to the console.
- `zig build --verbose example-multithreaded-http -- otlp 20 0.5` - run a comprehensive test for 20 seconds using the otlp exporter and sampling 50%.
- `zig build -l` - to list all the build targets and to find one not on this list.

## Running individual files

The commands `zig run` or `zig test` don't use the build system. To use these commands, you must be explicit with the dependencies for what you are trying to do. And you must run them from the project root directory.

The commands work like this `zig (run|test) ((--dep "other-module-name")* -Mthis-module-name)*`. The first module provided is always expected to be the `main` module -- the one you are actually trying to run. Every module you add after that is a dependent module. Each `-Mthis-module-name` needs the `--dep` flags for it's dependencies before it.

For example, to run the debug hang file, you would use this command:

```bash
# For a file that only needs the API:
zig test -Mroot=some_api_test.zig -Motel-api=src/api/root.zig

# For a file that needs API + SDK:
zig test --dep "otel-api" -Mroot=some_sdk_test.zig -Motel-api=src/api/root.zig -Motel-sdk=src/sdk/root.zig

# Complex example
timeout 60s zig run --dep "otel-api" --dep "otel-sdk" --dep "otel-exporters" -Mroot=debug_hang.zig -Motel-api=src/api/root.zig --dep "otel-api" -Motel-sdk=src/sdk/root.zig --dep "otel-api" --dep "otel-sdk" --dep "protobuf" -Motel-exporters=src/exporters/root.zig -Mprotobuf=/Users/jwatson/.cache/zig/p/protobuf-2.0.0-0e82akObGwBZQtrB7Qb6CTWSrwYKRPJ0M4L0CuTJmJ9G/src/protobuf.zig
```

Helpful hints:
- otel-api: doesn't have any dependencies.
- otel-sdk: `--dep "otel-api"`
- otel-exporters: `--dep "otel-api" --dep "otel-sdk"` and protobuf

You can normally find the path to protobuf under the `.cache` directory.

## Architecture Overview

This is a Zig implementation of the OpenTelemetry API and SDK following the official OpenTelemetry specification. The codebase is structured with clear separation between API interfaces and SDK implementations. While this implementation tries to follow the specification closely, [where it makes more zig sense, we diverge](https://github.com/nodejs/node/issues/57992#issuecomment-2844248550).

See README.md for module structure and the Provider→Processor→Exporter flow overview.

### Bridge Pattern Architecture

The codebase uses a bridge pattern to separate API from SDK:

- **API Layer**: Defines interfaces using tagged unions (`Logger`, `LoggerProvider`, etc.)
- **Bridge Types**: Enable SDK implementations to plug into API interfaces. These are provided in the API layer and use template metaprogramming (`LoggerProviderBridge`)
- **SDK Layer**: Provides concrete implementations (`sdk.Logger`, `sdk.LoggerProvider`, `sdk.BasicTracerProvider`, etc.)

### Memory Management

All API types are **non-owning** - they hold references, not owned data. Callers are responsible for data lifetime management. The SDK tries to avoid creating new variants unless required. Usually a cloning method added to the API is sufficient (e.g. `AttributeKeyValue` has `initOwned()`, `initOwnedSlice`, `deinitOwned`, and `deinitOwnedSlice`). Types and collections are usually immutable. A builder should be used when cases of mutability are required (e.g. `AttributeBuilder`). In many cases, you can pass an empty, non-owning slice to things via `&.{}`.

SDK types have more flexibility in terms of owning the memory and mutability.

Exporters and Processors should copy and own memory when they are buffering or otherwise asynchronously using data.

## Key Patterns

### Builder
There is a generic provided `Builder` type under `api.common`. It currently powers the `AttributeBuilder`, `BaggageBuilder`, and `ContextBuilder`. All of their usage is similar to below.

```zig
// example use builder.
const resource = try AttributeBuilder.init(allocator)
    .add(.{.key = "attributeKey", .value .{ .string = "attributeValue"}})
    .finish(allocator);
```

The builders have a `build()` and a `finish` method. The build method does not deinit the builder. The finish method does. In both cases, the slice returned is considered owned and the caller must free it.

### Instrumentation Scope
Every logger/meter/tracer has an associated `InstrumentationScope` that identifies the instrumentation library (name, version, schema_url, attributes).

### Attribute System
- `AttributeValue`: Type-safe union supporting primitives and arrays
- `AttributeKeyValue`: Key-value pairs for metadata
- `AttributeBuilder`: Functional-style builder for attribute collections

```zig
// AttributeValue variants - note the field names:
const attr_value = AttributeValue{
    .bool = true,           // Boolean values
    .int = 42,              // NOT .int_value - common mistake
    .float = 3.14,          // IEEE 754 double
    .string = "hello",      // Non-owning slice
    .bool_array = &[_]bool{true, false},
    .int_array = &[_]i64{1, 2, 3},
    .float_array = &[_]f64{1.1, 2.2},
    .string_array = &[_][]const u8{"a", "b"},
};

// Creating attributes for spans/logs/metrics:
const attributes = &[_]AttributeKeyValue{
    .{ .key = "service.name", .value = .{ .string = "my-service" } },
    .{ .key = "http.status_code", .value = .{ .int = 200 } },
    .{ .key = "request.timeout", .value = .{ .float = 30.0 } },
    .{ .key = "feature.enabled", .value = .{ .bool = true } },
};
```

**Memory Management**: AttributeValue is non-owning by default. Use `initOwned()` methods when you need to clone string data.

### Pipeline System
The SDK uses a pipeline architecture for connecting processors and exporters with proper memory ownership.

```zig
// Pipeline Template Structure:
pub const PipelineStep = PipelineStepInstructions(
    ConcreteType,         // Your implementation (e.g., MyExporter, can often be `@This()`)
    InterfaceType,        // Union interface (e.g., SpanExporter)
    ConfigType,           // Configuration struct (use void if none)
    convertFunction,      // Converts concrete to interface
    initFunction,         // Initializes the concrete type
    connectFunction,      // Handles connection/cleanup
);
```

**Memory Ownership Chain**: Provider → Processor → Exporter
- Provider owns processors, **must** call `processor.deinit()` and `processor.destroy()` in its `deinit()`
- Processor owns exporter, **must** call `exporter.deinit()` and `exporter.destroy()` in its `deinit()`
- Each component cleans up what it was connected to via `.flowTo()`

**Testing**: The sdk provides a mock exporter (usually in the exporter.zig file) that can be used in testing to "collect" records. A `noop` exporter can be used to create a discarding exporter.

### Global Provider Registry
Thread-safe global provider management through `provider_registry.zig` with mutex-protected storage.

`setupGlobalProvider` takes an `anytype` tuple — each item becomes an independent `registerProcessor`/`registerReader` call, so multiple items fan out to multiple exporters. See README.md for usage examples.

### Span Lifecycle
Two-phase pattern where `.end()` marks span completion and `.deinit()` handles memory cleanup, following Zig RAII patterns. Spans remain queryable after ending but become non-recording.

`Span.deinit()` frees the span context (including `trace_state`) via `bridge.ctx.deinit(bridge.allocator)` for recording spans. Dropped (noop) spans never allocate `trace_state`. `SpanData.initOwned`/`deinitOwned` also own their copy of `ctx.trace_state` and `parent_ctx.trace_state` for processors that buffer asynchronously.

## Current State

The logs, metrics, and tracing implementations are complete and architecturally consistent. All three signals use identical patterns for provider setup, pipeline configuration, and memory management.

Semantic conventions has not been started.

Exporters are complete for OTLP and *Io.Writer, with full PipelineStep integration and batch processing support.

The examples serve as comprehensive integration tests and demonstrate proper usage patterns for all three signals. `examples/multithreaded_http_telemetry.zig` is the most comprehensive in that it exercises all three signals, W3C trace context propagation (including `tracestate`), and most of the SDK and exporter functionality.

## Testing Utilities

The codebase provides mock implementations for clean, testable code without stderr output or external dependencies.

### MockErrorHandler

Located in `src/api/common/error_handler.zig`, captures OpenTelemetry errors for verification instead of printing to stderr:

```zig
// Initialize mock error handler
var mock_error_handler = api.common.MockErrorHandler.init(allocator);
defer mock_error_handler.deinit();
api.common.setMockErrorHandler(&mock_error_handler);
defer api.common.clearMockErrorHandler();

// Test code that generates errors...

// Verify captured errors
try testing.expectEqual(@as(usize, 1), mock_error_handler.errorCount());
const error_info = mock_error_handler.getError(0).?;
try testing.expectEqual(api.common.Component.tracer, error_info.component);
try testing.expectEqual(api.common.ErrorType.validation, error_info.error_type);
try testing.expectEqualStrings("Expected error message", error_info.message);
```

**Key Methods:**
- `errorCount()` - Number of captured errors
- `getError(index)` - Get error info by index
- `clearErrors()` - Reset collected errors
- `hasErrorWithMessage(message)` - Check for specific error messages
- `hasErrorWithComponent(component)` - Check for errors from specific components
- `hasErrorWithType(error_type)` - Check for specific error types

**Best Practice:** Always use these mock handlers in tests to keep test output clean and enable verification of error conditions without relying on stderr inspection.

## Local Resources
The OTel specification is in the `spec` directory. The protobuf definitions are in the `opentelemetry-proto` directory.
