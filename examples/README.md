# OpenTelemetry Zig Examples

This directory contains example programs demonstrating the OpenTelemetry Zig implementation across different telemetry signals (logs, metrics, traces).

## Examples Overview

### Logging Examples
- `dns_query_logging.zig` - Basic DNS query with structured logging using console exporter
- `dns_query_logging_otlp.zig` - DNS query logging with OTLP export to collector

### Metrics Examples
- `metrics_histogram_otlp.zig` - Histogram metrics with OTLP export

### Comprehensive Multi-threaded Example
- `multithreaded_http_telemetry.zig` - **Complete observability showcase** featuring:
  - All three telemetry signals (logs, metrics, traces) 
  - Multi-threading with W3C trace context propagation
  - Metric views with attribute filtering and renaming
  - Observable gauges with async callbacks
  - Span events and links demonstrating relationships
  - Batch processing with different intervals
  - Realistic HTTP client/server simulation
  - Error handling and overflow detection
  - Memory-safe implementation with proper cleanup

### Tracing Examples  
- `simple_trace_sdk.zig` - Basic trace SDK demonstration with console export
- `simple_trace_otlp.zig` - Basic trace SDK with OTLP export to collector
- `comprehensive_trace_sdk.zig` - **Advanced trace SDK showcase** (detailed below)

## Builder Pattern Usage

All examples now use the consistent **setup.zig builder pattern** for easy configuration:

```zig
// Logs setup
try otel_sdk.logs.buildProvider(allocator)
    .withExporterClosure(config, createLogExporterWithConfig)
    .withBasicProcessor()
    .withDefaultResource()
    .withBasicProvider()
    .finish();
defer otel_sdk.logs.destroyProvider();

// Metrics setup  
try otel_sdk.metrics.buildProvider(allocator)
    .withExporterClosure(config, createMetricExporterWithConfig)
    .withPeriodicProcessor(30000) // 30 second intervals
    .withDefaultResource()
    .withBasicProvider()
    .finish();
defer otel_sdk.metrics.destroyProvider();

// Traces setup
try otel_sdk.trace.buildProvider(allocator)
    .withExporterClosure(config, createTraceExporterWithConfig)
    .withBatchProcessor(2000, 100) // 2s interval, 100 span queue
    .withResource(custom_resource)
    .withConfigurableProvider(sampler, id_generator, span_limits)
    .finish();
defer otel_sdk.trace.destroyProvider();
```

## Sampling Strategies Example

The `test_sampling.zig` example demonstrates all available sampling strategies:

### Featured Samplers
1. **AlwaysOff** - Drops all spans (for production traffic reduction)
2. **AlwaysOn** - Samples all spans (for development/debugging)
3. **TraceIdRatioBased** - Samples based on trace ID ratio (0.0 to 1.0)
4. **ParentBased** - Follows parent span sampling decisions

### Sample Output
```
=== OpenTelemetry Sampling Test ===

1. Testing AlwaysOff Sampler (should drop all spans):
[No output - spans dropped]

2. Testing AlwaysOn Sampler (should sample all spans):
{"resourceSpans":[...]} // Full OTLP JSON trace

5. Testing TraceIdRatioBased Sampler with 50% ratio:
   Sampled 4 out of 10 spans (40%)

6. Testing ParentBased Sampler with AlwaysOn root sampler:
   Root span sampled: true
   Child span sampled: true (should match parent: true)
```

### Running the Sampling Test
```bash
zig build example-sampling-test
```

## Batch Processing Examples

### Batch Spans (`batch_spans.zig`)
Demonstrates the **BatchSpanProcessor** for efficient span export:
- **2-second export intervals** - Batches spans for periodic export
- **Queue management** - Up to 100 spans queued before forcing export
- **Background processing** - Non-blocking span collection

### Simple Batch Test (`simple_batch_test.zig`)
Quick validation of batch processing with:
- **500ms export intervals** - Fast testing cycle
- **Small queue size** - 5 spans for immediate feedback
- **Force flush testing** - Manual export triggering

## Comprehensive Trace SDK Example

The `comprehensive_trace_sdk.zig` example is a comprehensive demonstration of the OpenTelemetry Trace SDK capabilities, simulating realistic microservice scenarios using the new **setup.zig builder pattern**.

### Features Demonstrated

#### 1. HTTP Request Scenario 📡
Simulates a complete web service request flow:
- **API Gateway** (SERVER span) - receives POST /api/orders request
- **User Service** (INTERNAL span) - validates user credentials
- **Database Query** (CLIENT span) - PostgreSQL user lookup
- **Order Service** (INTERNAL span) - processes order creation

**Key Features:**
- Parent-child span relationships with proper trace/span ID propagation
- HTTP semantic conventions (method, URL, status codes, user agent)
- Database semantic conventions (system, statement, operation)
- Span events (request validation, inventory checks)
- Success status with custom messages

#### 2. Error Handling Scenario ❌
Demonstrates proper error handling and status reporting:
- **Payment Service** (SERVER span) - processes payment request
- **Card Validation** (INTERNAL span) - validates credit card (fails)

**Key Features:**
- Error status codes (Status.err) with descriptive messages
- Error events with structured error information
- Proper error attribute propagation from child to parent spans
- Realistic payment processing failure scenarios

#### 3. Message Queue Scenario 📨
Shows asynchronous messaging patterns:
- **Producer** (PRODUCER span) - publishes order.created event to RabbitMQ
- **Consumer** (CONSUMER span) - receives and processes the message
- **Event Processing** (INTERNAL span) - handles the order event

**Key Features:**
- Messaging semantic conventions (system, destination, operation)
- Message metadata (message ID, payload size, envelope size)
- Producer/Consumer span kinds for proper distributed tracing
- Event processing with inventory updates

#### 4. Concurrent Operations Scenario 🔄
Demonstrates batch processing and concurrent operations:
- **Batch Operation** (SERVER span) - coordinates multiple user lookups
- **Multiple Database Queries** (CLIENT spans) - concurrent user queries

**Key Features:**
- Sequential processing simulation with variable timing
- Batch operation metadata (size, type, status)
- Individual operation tracking within batch context
- Performance metrics for each query

#### 5. Performance Test Scenario ⚡
Tests trace SDK performance characteristics:
- **Performance Test** (INTERNAL span) - measures span creation overhead
- **Fast Operations** (INTERNAL spans) - rapid span creation/completion

**Key Features:**
- High-frequency span creation (10 operations)
- Performance measurement and reporting
- Nanosecond precision timing
- Average span creation time calculation

### Running Examples

```bash
# Comprehensive example (recommended starting point)
zig build example-multithreaded-http

# Individual examples
zig build example-simple-trace-sdk
zig build example-simple-trace-otlp  
zig build example-comprehensive-trace-sdk

# Metrics examples
zig build example-metrics-otlp

# Log examples  
zig build example-dns-query
zig build example-dns-query-otlp

# Build and run all examples
zig build examples
```

### OTLP Collector Setup

For OTLP examples, ensure you have an OpenTelemetry Collector running:

```bash
# Using Docker
docker run --rm -p 4317:4317 -p 4318:4318 \
  otel/opentelemetry-collector-contrib:latest

# Or configure your own collector on localhost:4318
```

### Output Format

The example exports traces in **OTLP JSON format** to the console. Each trace contains:

- **Resource attributes** - Service identification and metadata
- **Instrumentation scope** - Component that created the spans
- **Span data** - Timing, attributes, events, status, and relationships

Example trace output:
```json
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "comprehensive-trace-demo"}},
        {"key": "service.version", "value": {"stringValue": "2.0.0"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "api-gateway"},
      "spans": [{
        "traceId": "75caf3f8fdf922c34fbbab35aec8f13f",
        "spanId": "e5b6473f7b154271",
        "name": "POST /api/orders",
        "kind": 2,
        "startTimeUnixNano": "1750411730698338000",
        "endTimeUnixNano": "1750411730705341000",
        "attributes": [
          {"key": "http.method", "value": {"stringValue": "POST"}},
          {"key": "http.status_code", "value": {"intValue": "201"}}
        ],
        "events": [{
          "name": "request.validation.started",
          "attributes": [{"key": "validation.schema_version", "value": {"stringValue": "v1.2"}}]
        }],
        "status": {"code": 1, "message": "Order created successfully"}
      }]
    }]
  }]
}
```

### Technical Highlights

#### OpenTelemetry Compliance
- Full **OpenTelemetry specification** compliance
- Proper **semantic conventions** for HTTP, database, and messaging
- **W3C Trace Context** propagation (trace ID, span ID, parent relationships)

#### Span Relationships
- **Parent-child relationships** - Child spans reference parent span IDs
- **Trace correlation** - All related spans share the same trace ID
- **Context propagation** - Proper context passing between service boundaries

#### Performance Characteristics
- **Zero-allocation** design for span operations (where possible)
- **Efficient OTLP JSON export** using protobuf-generated types
- **Nanosecond precision** timing for accurate performance measurement

#### Memory Management
- **Caller-owned memory model** - Application manages attribute/event memory
- **Automatic resource cleanup** - Proper deinitialization of SDK components
- **Allocator-based design** - Consistent memory management patterns

### Integration Testing

This example serves as an integration test for the trace SDK, validating:

- ✅ **Span creation and lifecycle management**
- ✅ **Attribute and event addition**
- ✅ **Status setting (OK and Error states)**
- ✅ **Parent-child span relationships**
- ✅ **Context propagation between spans**
- ✅ **Multiple span kinds** (SERVER, CLIENT, INTERNAL, PRODUCER, CONSUMER)
- ✅ **OTLP JSON export format**
- ✅ **Resource and instrumentation scope metadata**
- ✅ **High-frequency span creation** (performance testing)
- ✅ **Error handling and status reporting**

## SDK Implementation Status

The OpenTelemetry Zig SDK implementation is **fully functional** across all three signals:

### ✅ Logs SDK (Complete)
- **Console and OTLP exporters** - Structured logging with export capabilities
- **Simple log processor** - Immediate log processing and export
- **Resource detection** - Automatic host and process metadata
- **Builder pattern setup** - Easy configuration and setup

### ✅ Metrics SDK (Complete) 
- **Console and OTLP exporters** - Metrics export in multiple formats
- **Periodic processor** - Configurable metric collection intervals
- **All instrument types** - Counter, UpDownCounter, Gauge, Histogram
- **Aggregation support** - Sum, LastValue, and Histogram aggregations
- **Builder pattern setup** - Consistent configuration approach

### ✅ Traces SDK (Complete)
- **Console and OTLP exporters** - Distributed tracing export
- **Simple and Batch processors** - Immediate and batched span processing
- **Full sampling support** - AlwaysOn/Off, Ratio-based, Parent-based
- **Span relationships** - Parent-child links with proper context propagation
- **All span kinds** - Server, Client, Internal, Producer, Consumer
- **Performance optimized** - Efficient span creation and processing
- **Builder pattern setup** - Flexible provider configuration

### Key Features Across All SDKs
- 🏗️ **Unified builder pattern** - Consistent setup across logs, metrics, traces
- 🔧 **Flexible configuration** - Custom exporters, processors, resources, samplers
- 🚀 **High performance** - Zero-allocation designs where possible
- 📊 **OTLP compliance** - Full OpenTelemetry Protocol support
- 🎯 **Memory safe** - Proper Zig memory management patterns
- 📈 **Production ready** - Comprehensive error handling and resource cleanup

## OTLP/HTTP transport backend selection

The OTLP examples run against the default `std.http` transport. To run them
through the opt-in httpx.zig backend, add `-Dotlp-httpx` to any example
invocation:

```sh
zig build -Dotlp-httpx example-simple-trace-otlp
zig build -Dotlp-httpx example-metrics-otlp
zig build -Dotlp-httpx example-dns-query-std-log-otlp
```

The flag is compile-time: no example source changes. The httpx dependency is
lazily resolved only under this flag, so a default build fetches nothing.

### Ready for Production Use

The SDK is ready for:

1. **Real-world application integration** - All core functionality implemented
2. **Custom exporter development** - Clean interfaces for new backends
3. **Advanced configurations** - Sampling, batching, resource detection
4. **Performance-critical applications** - Optimized for minimal overhead
5. **Large-scale deployments** - Robust memory and resource management

The OpenTelemetry Zig SDK successfully provides all the core functionality needed for observability in Zig applications! 🎉
