//! Provides a bridge between the Span type and the underlying
//! main field structure and the VTable for the more complex
//! operations.

const std = @import("std");
const api = struct {
    const AttributeKeyValue = @import("../common/attributes.zig").AttributeKeyValue;
    const trace = struct {
        const Span = @import("span.zig").Span;
    };
};

const Bridge = @This();

ctx: api.trace.Span.Context,
parent_ctx: ?api.trace.Span.Context,
kind: api.trace.Span.Kind,
start_ns: i64,
end_ns: ?i64,
is_recording: bool,
allocator: std.mem.Allocator,

span_ptr: *anyopaque,
updateNameFn: *const fn (span_ptr: *anyopaque, new_name: []const u8) void,
setStatusFn: *const fn (span_ptr: *anyopaque, status: api.trace.Span.Status) void,
setAttributeFn: *const fn (span_ptr: *anyopaque, entry: api.AttributeKeyValue) void,
setAttributesFn: *const fn (span_ptr: *anyopaque, entries: []const api.AttributeKeyValue) void,
addEventFn: *const fn (span_ptr: *anyopaque, event: api.trace.Span.Event) anyerror!void,
addLinkFn: *const fn (span_ptr: *anyopaque, link: api.trace.Span.Link) anyerror!void,
addLinksFn: *const fn (span_ptr: *anyopaque, links: []const api.trace.Span.Link) anyerror!void,
recordExceptionFn: *const fn (span_ptr: *anyopaque, exception: anyerror, attributes: ?[]const api.AttributeKeyValue, timestamp_ns: ?i64) anyerror!void,
endFn: *const fn (span_ptr: *anyopaque, bridge: Bridge, options: ?api.trace.Span.EndOptions) void,
deinitFn: *const fn (span_ptr: *anyopaque) void,

pub fn init(
    ptr: anytype,
    ctx: api.trace.Span.Context,
    parent_ctx: ?api.trace.Span.Context,
    kind: api.trace.Span.Kind,
    start_ns: i64,
    end_ns: ?i64,
    is_recording: bool,
    allocator: std.mem.Allocator,
) @This() {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);

    const VTable = struct {
        pub fn updateName(pointer: *anyopaque, new_name: []const u8) void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.updateName(self, new_name);
        }
        pub fn setStatus(pointer: *anyopaque, new_status: api.trace.Span.Status) void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.setStatus(self, new_status);
        }
        pub fn setAttribute(pointer: *anyopaque, entry: api.AttributeKeyValue) void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.setAttribute(self, entry);
        }
        pub fn setAttributes(pointer: *anyopaque, entries: []const api.AttributeKeyValue) void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.setAttributes(self, entries);
        }
        pub fn addEvent(pointer: *anyopaque, event: api.trace.Span.Event) anyerror!void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.addEvent(self, event);
        }
        pub fn addLink(pointer: *anyopaque, link: api.trace.Span.Link) anyerror!void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.addLink(self, link);
        }
        pub fn addLinks(pointer: *anyopaque, links: []const api.trace.Span.Link) anyerror!void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.addLinks(self, links);
        }
        pub fn recordException(pointer: *anyopaque, exception: anyerror, attributes: ?[]const api.AttributeKeyValue, timestamp_ns: ?i64) anyerror!void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.recordException(self, exception, attributes, timestamp_ns);
        }
        pub fn end(pointer: *anyopaque, bridge: Bridge, options: ?api.trace.Span.EndOptions) void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.end(self, bridge, options);
        }
        pub fn deinit(pointer: *anyopaque) void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.deinit(self);
        }
    };

    return .{
        .ctx = ctx,
        .parent_ctx = parent_ctx,
        .kind = kind,
        .start_ns = start_ns,
        .end_ns = end_ns,
        .is_recording = is_recording,
        .allocator = allocator,

        .span_ptr = ptr,
        .updateNameFn = VTable.updateName,
        .setStatusFn = VTable.setStatus,
        .setAttributeFn = VTable.setAttribute,
        .setAttributesFn = VTable.setAttributes,
        .addEventFn = VTable.addEvent,
        .addLinkFn = VTable.addLink,
        .addLinksFn = VTable.addLinks,
        .recordExceptionFn = VTable.recordException,
        .endFn = VTable.end,
        .deinitFn = VTable.deinit,
    };
}
