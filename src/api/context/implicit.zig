//! Implicit thread-local context propagation.
//!
//! Implements the OTel spec's optional implicit context layer:
//! https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/context/context.md
//!
//! Usage pattern:
//!
//!   const ctx = try withActiveSpanContext(allocator, &.{}, span.getSpanContext());
//!   defer ContextKeyValue.deinitOwnedSlice(allocator, ctx);
//!   const token = implicit.attach(ctx);
//!   defer implicit.detach(token);
//!
//!   // Elsewhere in the call stack, no ctx parameter needed:
//!   const active = api.trace.getActiveSpan();

const std = @import("std");
const ContextKeyValue = @import("context.zig").ContextKeyValue;

threadlocal var implicit_context: []const ContextKeyValue = &.{};

/// Returned by attach(). Must be passed to detach() to restore the prior context.
pub const Token = struct {
    previous: []const ContextKeyValue,
};

/// Returns the current thread-local context. Non-owning — caller must not free.
pub fn getCurrent() []const ContextKeyValue {
    return implicit_context;
}

/// Makes ctx the implicit context for this thread.
/// The caller is responsible for keeping ctx alive until detach() is called.
/// Always pair with `defer detach(token)` immediately after calling this.
pub fn attach(ctx: []const ContextKeyValue) Token {
    const token = Token{ .previous = implicit_context };
    implicit_context = ctx;
    return token;
}

/// Restores the context saved in token. Must be called after every attach().
pub fn detach(token: Token) void {
    implicit_context = token.previous;
}

test "attach and detach round-trip" {
    const testing = std.testing;

    const original = getCurrent();

    const fake_ctx = &[_]ContextKeyValue{};
    const token = attach(fake_ctx);
    defer detach(token);

    try testing.expectEqual(fake_ctx, getCurrent());
    detach(token);
    try testing.expectEqual(original, getCurrent());
}

test "nested attach/detach restores outer context" {
    const testing = std.testing;

    const outer = &[_]ContextKeyValue{};
    const inner = &[_]ContextKeyValue{};

    const outer_token = attach(outer);
    defer detach(outer_token);
    try testing.expectEqual(outer, getCurrent());

    const inner_token = attach(inner);
    try testing.expectEqual(inner, getCurrent());
    detach(inner_token);

    try testing.expectEqual(outer, getCurrent());
}
