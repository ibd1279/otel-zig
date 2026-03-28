//! OpenTelemetry SDK Recording Span Implementation
//!
//! This module provides the concrete implementation of the Span interface
//! for the SDK. RecordingSpan accumulates telemetry data during its lifetime
//! and becomes immutable after ending.

const std = @import("std");
const api = @import("otel-api");

const Span = api.trace.Span;
const AttributeValue = api.common.AttributeValue;
const AttributeKeyValue = api.common.AttributeKeyValue;
const OpenTelemetryError = api.common.OpenTelemetryError;
const Context = api.Context;

// Import validation functions from API layer
const validateAttributeKey = api.trace.validateAttributeKey;
const validateSpanName = api.trace.validateSpanName;
const reportValidationError = api.common.reportValidationError;

const SpanLimits = api.trace.SpanLimits;

const StandardTracer = @import("tracer.zig").StandardTracer;

// Span data represents the immutable span after it has ended.
pub const SpanData = struct {
    // span identification
    scope: api.InstrumentationScope,
    ctx: api.trace.Span.Context,
    parent_ctx: ?api.trace.Span.Context,

    // span description
    name: []const u8,
    kind: api.trace.Span.Kind,
    status: api.trace.Span.Status,
    start_time: std.Io.Timestamp,
    end_time: std.Io.Timestamp,
    attributes: []api.AttributeKeyValue,

    // sub-collections
    events: []api.trace.Span.Event,
    links: []api.trace.Span.Link,

    pub fn initOwned(allocator: std.mem.Allocator, unowned: SpanData) !SpanData {
        const name = try allocator.dupe(u8, unowned.name);
        errdefer allocator.free(name);

        const status = api.trace.Span.Status{
            .code = unowned.status.code,
            .description = if (unowned.status.description) |desc| try allocator.dupe(u8, desc) else null,
        };
        errdefer if (status.description) |desc| allocator.free(desc);

        const attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, unowned.attributes);
        errdefer api.AttributeKeyValue.deinitOwnedSlice(allocator, attributes);

        const events = try allocator.alloc(Span.Event, unowned.events.len);
        errdefer allocator.free(events);
        for (0..unowned.events.len) |h| {
            errdefer for (0..h) |i| {
                if (h == i) break;
                allocator.free(events[i].name);
                api.AttributeKeyValue.deinitOwnedSlice(allocator, events[i].attributes);
            };

            const event_name = try allocator.dupe(u8, unowned.events[h].name);
            errdefer allocator.free(event_name);

            const event_attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, unowned.events[h].attributes);
            errdefer api.AttributeKeyValue.deinitOwnedSlice(allocator, event_attributes);

            events[h] = .{
                .timestamp = unowned.events[h].timestamp,
                .name = event_name,
                .attributes = event_attributes,
            };
        }
        errdefer for (events) |event| {
            allocator.free(event.name);
            api.AttributeKeyValue.deinitOwnedSlice(allocator, event.attributes);
        };

        const links = try allocator.alloc(api.trace.Span.Link, unowned.links.len);
        errdefer allocator.free(links);
        for (0..unowned.links.len) |h| {
            errdefer for (0..h) |i| {
                if (h == i) break;
                api.AttributeKeyValue.deinitOwnedSlice(allocator, links[i].attributes);
            };

            const link_attributes = try api.AttributeKeyValue.initOwnedSlice(allocator, unowned.links[h].attributes);
            errdefer api.AttributeKeyValue.deinitOwnedSlice(allocator, link_attributes);

            links[h] = .{
                .span_context = unowned.links[h].span_context,
                .attributes = link_attributes,
            };
        }
        errdefer for (links) |link| api.AttributeKeyValue.deinitOwnedSlice(allocator, link.attributes);

        const ctx = blk: {
            var c = unowned.ctx;
            c.trace_state = if (unowned.ctx.trace_state) |ts| try allocator.dupe(u8, ts) else null;
            break :blk c;
        };
        errdefer ctx.deinit(allocator);

        const parent_ctx = if (unowned.parent_ctx) |pc| blk: {
            var c = pc;
            c.trace_state = if (pc.trace_state) |ts| try allocator.dupe(u8, ts) else null;
            break :blk c;
        } else null;
        errdefer if (parent_ctx) |pc| pc.deinit(allocator);

        return SpanData{
            .scope = unowned.scope,
            .ctx = ctx,
            .parent_ctx = parent_ctx,
            .name = name,
            .kind = unowned.kind,
            .status = status,
            .start_time = unowned.start_time,
            .end_time = unowned.end_time,
            .attributes = attributes,
            .events = events,
            .links = links,
        };
    }

    pub fn deinitOwned(self: SpanData, allocator: std.mem.Allocator) void {
        self.ctx.deinit(allocator);
        if (self.parent_ctx) |pc| pc.deinit(allocator);
        allocator.free(self.name);
        if (self.status.description) |desc| allocator.free(desc);
        api.AttributeKeyValue.deinitOwnedSlice(allocator, self.attributes);
        for (self.events) |event| {
            api.AttributeKeyValue.deinitOwnedSlice(allocator, event.attributes);
            allocator.free(event.name);
        }
        allocator.free(self.events);
        for (self.links) |link| {
            api.AttributeKeyValue.deinitOwnedSlice(allocator, link.attributes);
        }
        allocator.free(self.links);
    }
};

/// Bridge implementation for RecordingSpan to implement the Span interface
pub const RecordingSpan = struct {
    tracer: *StandardTracer,
    name: []const u8,
    status: api.trace.Span.Status,
    attributes: []api.AttributeKeyValue,
    events: std.ArrayList(api.trace.Span.Event),
    links: std.ArrayList(api.trace.Span.Link),

    pub fn init(tracer: *StandardTracer, name: []const u8) !RecordingSpan {
        const default_name = try tracer.provider.allocator.dupe(u8, name);
        errdefer tracer.provider.allocator.free(default_name);
        const default_attributes = try api.AttributeKeyValue.initOwnedSlice(tracer.provider.allocator, &.{});
        errdefer api.AttributeKeyValue.deinitOwnedSlice(tracer.provider.allocator, default_attributes);

        return .{
            .tracer = tracer,
            .name = default_name,
            .status = .default,
            .attributes = default_attributes,
            .events = .empty,
            .links = .empty,
        };
    }

    pub fn deinit(self: *RecordingSpan) void {
        self.tracer.provider.allocator.free(self.name);
        if (self.status.description) |desc| self.tracer.provider.allocator.free(desc);
        api.AttributeKeyValue.deinitOwnedSlice(self.tracer.provider.allocator, self.attributes);
        self.events.deinit(self.tracer.provider.allocator);
        self.links.deinit(self.tracer.provider.allocator);
        self.tracer.provider.allocator.destroy(self);
    }

    pub fn updateName(self: *RecordingSpan, new_name: []const u8) void {
        if (!validateSpanName(new_name)) {
            reportValidationError(.tracer, "Span.updateName", "Empty span name provided", null);
            // Continue with empty name (spec allows it, but we report it in debug)
        }
        const old_name = self.name;
        self.name = self.tracer.provider.allocator.dupe(u8, new_name) catch return;
        self.tracer.provider.allocator.free(old_name);
    }

    pub fn setStatus(self: *RecordingSpan, new_status: api.trace.Span.Status) void {
        if (self.status.description) |desc| self.tracer.provider.allocator.free(desc);
        const new_desc = if (new_status.description) |desc| self.tracer.provider.allocator.dupe(u8, desc) catch null else null;
        self.status = .{
            .code = new_status.code,
            .description = new_desc,
        };
    }

    pub fn setAttribute(self: *RecordingSpan, entry: AttributeKeyValue) void {
        const old_attributes = self.attributes;
        self.attributes = api.AttributeBuilder.init(self.tracer.provider.allocator)
            .addMany(old_attributes)
            .add(entry)
            .finish(self.tracer.provider.allocator) catch return;
        api.AttributeKeyValue.deinitOwnedSlice(self.tracer.provider.allocator, old_attributes);
    }

    pub fn setAttributes(self: *RecordingSpan, entries: []const AttributeKeyValue) void {
        const old_attributes = self.attributes;
        self.attributes = api.AttributeBuilder.init(self.tracer.provider.allocator)
            .addMany(old_attributes)
            .addMany(entries)
            .finish(self.tracer.provider.allocator) catch return;
        api.AttributeKeyValue.deinitOwnedSlice(self.tracer.provider.allocator, old_attributes);
    }

    pub fn addEvent(self: *RecordingSpan, event: api.trace.Span.Event) void {
        // TODO: this should deep copy the event for memeory safety.
        var e = event;
        if (e.timestamp == null) {
            e.timestamp = std.Io.Clock.real.now(self.tracer.provider.io) catch std.Io.Timestamp.zero;
        }
        self.events.append(self.tracer.provider.allocator, e) catch {};
    }

    pub fn addLink(self: *RecordingSpan, link: api.trace.Span.Link) anyerror!void {
        // TODO: this should deep copy the link for memory safety.
        self.links.append(self.tracer.provider.allocator, link) catch {};
    }

    pub fn addLinks(self: *RecordingSpan, links: []const api.trace.Span.Link) anyerror!void {
        // TODO: this should deep copy the links for memory safety.
        self.links.appendSlice(self.tracer.provider.allocator, links) catch {};
    }

    pub fn end(self: *RecordingSpan, bridge: api.trace.Span.Bridge, options: ?api.trace.Span.EndOptions) void {
        const default_ts = std.Io.Clock.real.now(self.tracer.provider.io) catch std.Io.Timestamp.zero;
        const end_ts = if (options) |opts| opts.end_time orelse default_ts else default_ts;

        // Notify processor if available
        for (self.tracer.provider.processors.items) |*processor| {
            processor.onEnd(SpanData{
                .scope = self.tracer.scope,
                .ctx = bridge.ctx,
                .parent_ctx = bridge.parent_ctx,
                .name = self.name,
                .kind = bridge.kind,
                .status = self.status,
                .start_time = bridge.start_time,
                .end_time = bridge.end_time orelse end_ts,
                .attributes = self.attributes,
                .events = self.events.items,
                .links = self.links.items,
            }, self.tracer.provider.resource);
        }
    }

    pub fn recordException(self: *RecordingSpan, exception: anyerror, attributes: ?[]const AttributeKeyValue, timestamp: ?std.Io.Timestamp) anyerror!void {
        // TODO: these names should come from semconv, if they are defined there.
        const convention_attributes = &[_]AttributeKeyValue{ .{
            .key = "exception.type",
            .value = AttributeValue{ .string = @errorName(exception) },
        }, .{
            .key = "exception.message",
            .value = AttributeValue{ .string = @errorName(exception) },
        } };

        const attrs_builder = api.AttributeBuilder.init(self.tracer.provider.allocator)
            .addMany(attributes orelse &.{})
            .addMany(convention_attributes);
        defer attrs_builder.deinit();

        const exception_attrs: ?[]api.AttributeKeyValue = attrs_builder.build() catch null;
        if (exception_attrs) |attrs| self.tracer.provider.allocator.free(attrs);

        const default_ts = std.Io.Clock.real.now(self.tracer.provider.io) catch std.Io.Timestamp.zero;
        self.addEvent(.{
            .name = "exception",
            .timestamp = timestamp orelse default_ts,
            .attributes = exception_attrs orelse convention_attributes,
        });
    }
};
