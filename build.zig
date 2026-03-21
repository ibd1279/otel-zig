const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // OpenTelemetry API Module
    // ========================================================================
    // Contains only interfaces, types, and noop implementations
    // This is what applications import for stable APIs
    const otel_api_mod = b.createModule(.{
        .root_source_file = b.path("src/api/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("otel-api", .{
        .root_source_file = b.path("src/api/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // OpenTelemetry SDK Core Module
    // ========================================================================
    // Contains basic SDK implementations (loggers, providers, processors)
    const otel_sdk_mod = b.createModule(.{
        .root_source_file = b.path("src/sdk/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    otel_sdk_mod.addImport("otel-api", otel_api_mod);

    _ = b.addModule("otel-sdk", .{
        .root_source_file = b.path("src/sdk/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_api_mod },
        },
    });

    // ========================================================================
    // OpenTelemetry protobuf generator
    // ========================================================================
    // Generate the otlp proto outputs
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    const gen_proto = b.step("gen-proto", "generates zig files for OTLP.");
    const protoc_step = @import("protobuf").RunProtocStep.create(protobuf_dep.builder, target, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/exporters/otlp/proto"),
        .source_files = &.{
            "opentelemetry-proto/opentelemetry/proto/logs/v1/logs.proto",
            "opentelemetry-proto/opentelemetry/proto/metrics/v1/metrics.proto",
            "opentelemetry-proto/opentelemetry/proto/trace/v1/trace.proto",
        },
        .include_directories = &.{
            "opentelemetry-proto/",
        },
    });

    gen_proto.dependOn(&protoc_step.step);

    // ========================================================================
    // OpenTelemetry SDK Exporters Module
    // ========================================================================
    // Contains concrete exporters (console, OTLP, etc.)

    const otel_exporters_mod = b.createModule(.{
        .root_source_file = b.path("src/exporters/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    otel_exporters_mod.addImport("otel-api", otel_api_mod);
    otel_exporters_mod.addImport("otel-sdk", otel_sdk_mod);
    otel_exporters_mod.addImport("protobuf", protobuf_dep.module("protobuf"));

    _ = b.addModule("otel-exporters", .{
        .root_source_file = b.path("src/exporters/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_api_mod },
            .{ .name = "otel-sdk", .module = otel_sdk_mod },
            .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
        },
    });

    // ========================================================================
    // OpenTelemetry Semantic Conventions Module
    // ========================================================================
    // Contains semantic conventions, can be used independently
    const otel_semconv_mod = b.createModule(.{
        .root_source_file = b.path("src/semconv/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("otel-semconv", .{
        .root_source_file = b.path("src/semconv/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Convenience "All-in-One" Module
    // ========================================================================
    // Re-exports everything for simple use cases
    const otel_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    otel_mod.addImport("otel-api", otel_api_mod);
    otel_mod.addImport("otel-sdk", otel_sdk_mod);
    otel_mod.addImport("otel-exporters", otel_exporters_mod);
    otel_mod.addImport("otel-semconv", otel_semconv_mod);

    _ = b.addModule("otel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_api_mod },
            .{ .name = "otel-sdk", .module = otel_sdk_mod },
            .{ .name = "otel-exporters", .module = otel_exporters_mod },
            .{ .name = "otel-semconv", .module = otel_semconv_mod },
        },
    });

    // ========================================================================
    // Libraries
    // ========================================================================

    // API library (minimal, stable)
    const api_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel-api",
        .root_module = otel_api_mod,
    });
    b.installArtifact(api_lib);

    // SDK library (full implementation)
    const sdk_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel-sdk",
        .root_module = otel_sdk_mod,
    });
    b.installArtifact(sdk_lib);

    // Exporters library
    const exporters_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel-exporters",
        .root_module = otel_exporters_mod,
    });
    b.installArtifact(exporters_lib);

    // All-in-one library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "otel",
        .root_module = otel_mod,
    });
    b.installArtifact(lib);

    // ========================================================================
    // Tests
    // ========================================================================

    // API tests
    const api_unit_tests = b.addTest(.{
        .root_module = otel_api_mod,
    });
    const run_api_tests = b.addRunArtifact(api_unit_tests);

    // SDK tests
    const sdk_unit_tests = b.addTest(.{
        .root_module = otel_sdk_mod,
    });
    const run_sdk_tests = b.addRunArtifact(sdk_unit_tests);

    // Exporters tests
    const exporters_unit_tests = b.addTest(.{
        .root_module = otel_exporters_mod,
    });
    const run_exporters_tests = b.addRunArtifact(exporters_unit_tests);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = otel_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Comprehensive error handling tests
    const comprehensive_error_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/error_handling_comprehensive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    comprehensive_error_tests.root_module.addImport("otel-api", otel_api_mod);
    comprehensive_error_tests.root_module.addImport("otel-sdk", otel_sdk_mod);
    comprehensive_error_tests.root_module.addImport("otel-exporters", otel_exporters_mod);
    const run_comprehensive_error_tests = b.addRunArtifact(comprehensive_error_tests);

    // Test steps
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_sdk_tests.step);
    test_step.dependOn(&run_exporters_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_comprehensive_error_tests.step);

    const test_api_step = b.step("test-api", "Run API tests only");
    test_api_step.dependOn(&run_api_tests.step);

    const test_sdk_step = b.step("test-sdk", "Run SDK tests only");
    test_sdk_step.dependOn(&run_sdk_tests.step);

    const test_exporters_step = b.step("test-exporters", "Run exporter tests");
    test_exporters_step.dependOn(&run_exporters_tests.step);

    const test_error_handling_step = b.step("test-error-handling", "Run comprehensive error handling tests");
    test_error_handling_step.dependOn(&run_comprehensive_error_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // DNS Query Logging Example
    const dns_query_example = b.addExecutable(.{
        .name = "dns_query_logging",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dns_query_logging.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dns_query_example.root_module.addImport("otel-api", otel_api_mod);
    dns_query_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    dns_query_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_dns_query = b.addRunArtifact(dns_query_example);
    const dns_query_step = b.step("example-dns-query", "Run DNS query logging example");
    dns_query_step.dependOn(&run_dns_query.step);

    // DNS Query Logging OTLP Example
    const dns_query_otlp_example = b.addExecutable(.{
        .name = "dns_query_logging_otlp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dns_query_logging_otlp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dns_query_otlp_example.root_module.addImport("otel-api", otel_api_mod);
    dns_query_otlp_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    dns_query_otlp_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_dns_query_otlp = b.addRunArtifact(dns_query_otlp_example);
    const dns_query_otlp_step = b.step("example-dns-query-otlp", "Run DNS query logging OTLP example");
    dns_query_otlp_step.dependOn(&run_dns_query_otlp.step);

    // DNS Query std.log Bridge Example
    const dns_query_std_log_console_example = b.addExecutable(.{
        .name = "dns_query_std_log_console",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dns_query_std_log_console.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dns_query_std_log_console_example.root_module.addImport("otel-api", otel_api_mod);
    dns_query_std_log_console_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    dns_query_std_log_console_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_dns_query_std_log_console = b.addRunArtifact(dns_query_std_log_console_example);
    const dns_query_std_log_console_step = b.step("example-dns-query-std-log-console", "Run DNS query std.log bridge console example");
    dns_query_std_log_console_step.dependOn(&run_dns_query_std_log_console.step);

    // DNS Query std.log Bridge OTLP Example
    const dns_query_std_log_otlp_example = b.addExecutable(.{
        .name = "dns_query_std_log_otlp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dns_query_std_log_otlp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dns_query_std_log_otlp_example.root_module.addImport("otel-api", otel_api_mod);
    dns_query_std_log_otlp_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    dns_query_std_log_otlp_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_dns_query_std_log_otlp = b.addRunArtifact(dns_query_std_log_otlp_example);
    const dns_query_std_log_otlp_step = b.step("example-dns-query-std-log-otlp", "Run DNS query std.log bridge OTLP example");
    dns_query_std_log_otlp_step.dependOn(&run_dns_query_std_log_otlp.step);

    // Comprehensive Metrics OTLP Example
    const metrics_comprehensive_otlp_example = b.addExecutable(.{
        .name = "metrics_comprehensive_otlp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/metrics_histogram_otlp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    metrics_comprehensive_otlp_example.root_module.addImport("otel", otel_mod);
    metrics_comprehensive_otlp_example.root_module.addImport("otel-api", otel_api_mod);
    metrics_comprehensive_otlp_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    metrics_comprehensive_otlp_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_metrics_comprehensive_otlp = b.addRunArtifact(metrics_comprehensive_otlp_example);
    const metrics_comprehensive_otlp_step = b.step("example-metrics-otlp", "Run comprehensive metrics OTLP example");
    metrics_comprehensive_otlp_step.dependOn(&run_metrics_comprehensive_otlp.step);

    // Simple Trace SDK Example
    const simple_trace_sdk_example = b.addExecutable(.{
        .name = "simple_trace_sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple_trace_sdk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    simple_trace_sdk_example.root_module.addImport("otel-api", otel_api_mod);
    simple_trace_sdk_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    simple_trace_sdk_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_simple_trace_sdk = b.addRunArtifact(simple_trace_sdk_example);
    const simple_trace_sdk_step = b.step("example-simple-trace-sdk", "Run simple trace SDK example");
    simple_trace_sdk_step.dependOn(&run_simple_trace_sdk.step);

    // Comprehensive Trace SDK Example
    const comprehensive_trace_sdk_example = b.addExecutable(.{
        .name = "comprehensive_trace_sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/comprehensive_trace_sdk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    comprehensive_trace_sdk_example.root_module.addImport("otel-api", otel_api_mod);
    comprehensive_trace_sdk_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    comprehensive_trace_sdk_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_comprehensive_trace_sdk = b.addRunArtifact(comprehensive_trace_sdk_example);
    const comprehensive_trace_sdk_step = b.step("example-comprehensive-trace-sdk", "Run comprehensive trace SDK example");
    comprehensive_trace_sdk_step.dependOn(&run_comprehensive_trace_sdk.step);

    // Simple Trace OTLP Example
    const simple_trace_otlp_example = b.addExecutable(.{
        .name = "simple_trace_otlp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple_trace_otlp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    simple_trace_otlp_example.root_module.addImport("otel-api", otel_api_mod);
    simple_trace_otlp_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    simple_trace_otlp_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_simple_trace_otlp = b.addRunArtifact(simple_trace_otlp_example);
    const simple_trace_otlp_step = b.step("example-simple-trace-otlp", "Run simple trace OTLP example");
    simple_trace_otlp_step.dependOn(&run_simple_trace_otlp.step);

    // Error Handling Demo Example
    const error_handling_demo_example = b.addExecutable(.{
        .name = "error_handling_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/error_handling_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    error_handling_demo_example.root_module.addImport("otel-api", otel_api_mod);
    error_handling_demo_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    error_handling_demo_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_error_handling_demo = b.addRunArtifact(error_handling_demo_example);
    const error_handling_demo_step = b.step("example-error-handling", "Run error handling demo example");
    error_handling_demo_step.dependOn(&run_error_handling_demo.step);

    // Validation Test Example
    const validation_test_example = b.addExecutable(.{
        .name = "validation_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/validation_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    validation_test_example.root_module.addImport("otel-api", otel_api_mod);
    validation_test_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    validation_test_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_validation_test = b.addRunArtifact(validation_test_example);
    const validation_test_step = b.step("example-validation-test", "Run validation test example");
    validation_test_step.dependOn(&run_validation_test.step);

    // Force Flush Test Example
    const force_flush_test_example = b.addExecutable(.{
        .name = "test_force_flush",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/test_force_flush.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    force_flush_test_example.root_module.addImport("otel-api", otel_api_mod);
    force_flush_test_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    force_flush_test_example.root_module.addImport("otel-exporters", otel_exporters_mod);

    const run_force_flush_test = b.addRunArtifact(force_flush_test_example);
    const force_flush_test_step = b.step("example-force-flush-test", "Run force flush test example");
    force_flush_test_step.dependOn(&run_force_flush_test.step);

    // Multithreaded HTTP Telemetry Example
    const multithreaded_http_example = b.addExecutable(.{
        .name = "multithreaded_http_telemetry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/multithreaded_http_telemetry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    multithreaded_http_example.root_module.addImport("otel-api", otel_api_mod);
    multithreaded_http_example.root_module.addImport("otel-sdk", otel_sdk_mod);
    multithreaded_http_example.root_module.addImport("otel-exporters", otel_exporters_mod);
    multithreaded_http_example.root_module.addImport("otel-semconv", otel_semconv_mod);

    const run_multithreaded_http = b.addRunArtifact(multithreaded_http_example);
    if (b.args) |args| {
        run_multithreaded_http.addArgs(args);
    }
    const multithreaded_http_step = b.step("example-multithreaded-http", "Run multithreaded HTTP telemetry example");
    multithreaded_http_step.dependOn(&run_multithreaded_http.step);

    // Examples install step (explicitly opt-in)
    const examples_install_step = b.step("examples-install", "Build and install example executables");
    const install_simple_trace_sdk = b.addInstallArtifact(simple_trace_sdk_example, .{});
    const install_comprehensive_trace_sdk = b.addInstallArtifact(comprehensive_trace_sdk_example, .{});
    const install_simple_trace_otlp = b.addInstallArtifact(simple_trace_otlp_example, .{});
    const install_error_handling_demo = b.addInstallArtifact(error_handling_demo_example, .{});
    const install_validation_test = b.addInstallArtifact(validation_test_example, .{});
    const install_force_flush_test = b.addInstallArtifact(force_flush_test_example, .{});
    const install_multithreaded_http = b.addInstallArtifact(multithreaded_http_example, .{});
    examples_install_step.dependOn(&install_simple_trace_sdk.step);
    examples_install_step.dependOn(&install_comprehensive_trace_sdk.step);
    examples_install_step.dependOn(&install_simple_trace_otlp.step);
    examples_install_step.dependOn(&install_error_handling_demo.step);
    examples_install_step.dependOn(&install_validation_test.step);
    examples_install_step.dependOn(&install_force_flush_test.step);
    examples_install_step.dependOn(&install_multithreaded_http.step);

    // All examples step (runs them)
    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(&run_dns_query.step);
    examples_step.dependOn(&run_dns_query_otlp.step);
    examples_step.dependOn(&run_dns_query_std_log_console.step);
    examples_step.dependOn(&run_dns_query_std_log_otlp.step);
    examples_step.dependOn(&run_metrics_comprehensive_otlp.step);
    examples_step.dependOn(&run_simple_trace_sdk.step);
    examples_step.dependOn(&run_comprehensive_trace_sdk.step);
    examples_step.dependOn(&run_simple_trace_otlp.step);

    examples_step.dependOn(&run_validation_test.step);
    examples_step.dependOn(&run_error_handling_demo.step);
    examples_step.dependOn(&run_validation_test.step);
    examples_step.dependOn(&run_force_flush_test.step);
    examples_step.dependOn(&run_multithreaded_http.step);
}
