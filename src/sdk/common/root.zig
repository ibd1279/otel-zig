//! OpenTelemetry SDK Common Utilities
//!
//! This module provides common utilities and types used across the SDK implementation.
//! These utilities are not part of the stable API and are used internally by the SDK.
//!
//! ## Components
//! - `Clock` - Time utilities and timestamp generation
//! - `IdGenerator` - Trace and span ID generation
//! - `Config` - Common configuration structures
//! - `Limits` - Resource and attribute limits
//!
//! ## Usage
//! These utilities are primarily for SDK implementers and should not be used
//! directly by applications unless building custom SDK components.

const std = @import("std");

// Configuration
const config_zig = @import("config.zig");
pub const Config = config_zig.Config;
pub const Limits = config_zig.Limits;
pub const AttributeLimits = config_zig.AttributeLimits;
pub const SpanLimits = config_zig.SpanLimits;
pub const LogRecordLimits = config_zig.LogRecordLimits;
pub const parseEnvironmentVariable = config_zig.parseEnvironmentVariable;
pub const getEnvironmentVariable = config_zig.getEnvironmentVariable;

// Pipeline Configuration
const pipeline_zig = @import("pipeline.zig");
pub const PipelineBuilder = pipeline_zig.PipelineBuilder;
pub const PipelineStepInstructions = pipeline_zig.PipelineStepInstructions;
pub const PipelineDeinitConnection = pipeline_zig.PipelineDeinitConnection;
pub const buildPipeline = pipeline_zig.buildPipeline;

// Instrumentation Scope Hash Map Context
pub const InstrumentationScopeMapContext = @import("scope_context.zig").InstrumentationScopeMapContext;

pub const batch_flush = @import("batch_flush.zig");

test {
    std.testing.refAllDecls(@This());
}
