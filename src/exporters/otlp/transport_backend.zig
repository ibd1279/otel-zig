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

pub const transport = if (build_options.otlp_httpx)
    @import("transport_httpx.zig")
else
    @import("transport.zig");
