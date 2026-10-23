//! Compile-time OTLP/HTTP transport backend selection.
//!
//! Exporter modules import the transport through this file and stay unaware
//! of which backend is active. The backend is chosen by the `otlp-httpx`
//! build option:
//!
//!   - default: the std.http-based transport in `transport.zig`
//!   - `-Dotlp-httpx`: the httpx.zig-backed variant in `transport_httpx.zig`
//!
//! Both backends expose the same `post()` signature and `Response` shape and
//! share the single retry layer in `transport.zig`.

const build_options = @import("build_options");
const base = @import("transport.zig");

pub const transport = if (build_options.otlp_httpx)
    @import("transport_httpx.zig")
else
    @import("transport.zig");

// The two backends must stay interchangeable: identical `post()` signature,
// identical `Response` shape, and the shared retry-layer re-exports present.
// Assigning each backend's `post` to the shared `PostFn` contract type
// coerces only when the full signature matches — signature drift on either
// backend is a compile error, complementing the header-layout assertions
// inside the httpx backend.
comptime {
    const default_post: base.PostFn = &@import("transport.zig").post;
    const selected_post: base.PostFn = &transport.post;
    _ = default_post;
    _ = selected_post;

    if (@TypeOf(transport.Response) != @TypeOf(@import("transport.zig").Response)) {
        @compileError("OTLP transport backends diverged: Response types differ between the default and selected backend");
    }
    const re_exports = [_][]const u8{
        "signalUrl",  "joinSignalPath", "isRetryableStatus",
        "retryDelay", "nextInterval",
    };
    for (re_exports) |name| {
        if (!@hasDecl(transport, name)) {
            @compileError("OTLP transport backend is missing the shared retry-layer re-export: " ++ name);
        }
    }

    // Deliberate extension (decision D3/D4): when the flag is on, BOTH
    // httpx-family backends must coerce to the shared PostFn contract —
    // the OTLP/HTTP variant above and the OTLP/gRPC variant in
    // transport_grpc.zig. The default build compiles neither, so this block
    // never references httpx there.
    if (build_options.otlp_httpx) {
        const grpc_post: base.PostFn = &transport.grpc.post;
        _ = grpc_post;
        if (@TypeOf(transport.grpc.Response) != @TypeOf(base.Response)) {
            @compileError("OTLP transport backends diverged: the gRPC backend's Response type differs from the shared contract");
        }
    }
}
