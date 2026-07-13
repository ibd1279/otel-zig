# Design: OTLP exporter endpoint/URL handling rework

**Status:** DRAFT — for review, not implemented this session.
**Affected code:** `src/exporters/otlp/traces.zig`, `logs.zig`, `metrics.zig` (all three duplicate the same logic).
**Motivating context:** found while reviewing the OTLP exporter with a downstream consumer (fonceuse/exutoire) debugging why endpoint-related config wasn't behaving as expected.

## Problem

All three OTLP exporters (`OtlpTraceExporter.sendRequest`, `OtlpLogExporter.sendRequest`,
`OtlpMetricExporter.sendRequest`) independently implement the same endpoint-URL handling,
copy-pasted with no shared code:

```zig
const uri = std.Uri.parse(self.config.endpoint) catch |err| { ... };

const host_str = switch (uri.host.?) {
    .raw => |raw| raw,
    .percent_encoded => |encoded| encoded,
};
const scheme_str = if (uri.scheme.len > 0) uri.scheme else "http";
const full_url = try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{
    scheme_str, host_str, uri.port orelse 4318, self.config.protocol_config.{traces,logs,metrics}_path,
});
...
const full_uri = try std.Uri.parse(full_url);
```

This has several concrete problems, in priority order:

1. **Silently drops any path/query/userinfo already present on `config.endpoint`.**
   Only scheme+host+port survive; the exporter's own fixed `{traces,logs,metrics}_path`
   is unconditionally appended in their place. A user who sets
   `endpoint = "http://collector:4318/some/prefix"` (e.g. because their collector sits
   behind a path-based reverse-proxy route) silently loses `/some/prefix` — no error,
   no log, just a request to the wrong path. Per the OTLP spec, a
   `OTEL_EXPORTER_OTLP_ENDPOINT`-style base endpoint should have `/v1/{signal}` appended
   *to whatever path is already present*, not have its path replaced outright.

2. **Hardcodes port 4318 as the fallback regardless of scheme.** 4318 is the OTLP/HTTP
   default; gRPC's default is 4317. Since this exporter only speaks HTTP today (per
   `Transport` enum and `OtlpExporterConfig` docs), 4318 is defensible *for now*, but the
   fallback is baked into three independent copy-pasted call sites rather than centralized,
   so it will drift if gRPC support is ever added to just one of the three.

3. **`uri.host.?` unwraps with a bare `.?`.** If `config.endpoint` parses successfully but
   has no host component (a technically-valid-but-useless URI, e.g. a relative reference,
   or a URI like `unix:///path` where host semantics don't apply the same way), this is an
   unchecked-null panic in a hot export path rather than a reported configuration error
   through the existing `error_handler.reportError` path already used two lines up for the
   parse-failure case.

4. **Double-parse (parse → reformat into a new string → re-parse).** Not a correctness
   bug, but wasteful: every single export call parses the configured endpoint twice and
   heap-allocates an intermediate string purely to reassemble scheme+host+port+path that
   were already available as parsed components after the first parse.

5. **Triplication.** The exact same ~10 lines exist independently in
   `traces.zig`, `logs.zig`, `metrics.zig`. Any fix applied to one (as has already
   happened at least once informally) needs to be manually ported to the other two,
   and nothing enforces that they stay in sync.

## Goals

- Preserve any path already present on `config.endpoint`, appending the signal-specific
  suffix (`/v1/traces`, `/v1/logs`, `/v1/metrics`) rather than replacing the path outright.
- Single shared implementation, used by all three exporters.
- Turn the `uri.host.?` unwrap into a reported configuration error (matching how a parse
  failure is already handled) instead of a panic.
- Eliminate the format-then-reparse round trip: build the final `std.Uri` from parsed
  components directly wherever `std.Uri`'s API allows constructing/mutating a `path` field,
  falling back to a single allocPrint + parse only if `std.Uri` doesn't expose a cheaper path.
- No behavior change for the common case (`endpoint = "http://host:port"`, no path) — this
  should be purely path-preservation-additive plus the panic→error fix, not a config format
  change requiring a user-visible migration.

## Non-goals

- Not adding gRPC transport support. The 4317-vs-4318 default-port question is noted for
  awareness but out of scope; if/when gRPC lands, it should decide its own port default at
  that point, using whatever shared endpoint-parsing this design introduces.
- Not changing `OtlpExporterConfig`'s field names or `ProtocolConfig`'s existing
  `{traces,logs,metrics}_path` fields — those stay as the signal-specific *suffix*, just
  joined onto the existing path instead of replacing it.

## Proposed approach

### 1. Shared helper

Add a single function, likely in `src/exporters/otlp/root.zig` or a new
`src/exporters/otlp/endpoint.zig`, with a signature along these lines:

```zig
/// Resolve the final request URI for one OTLP/HTTP export call: parses
/// `endpoint`, joins `signal_path` onto whatever path component (if any)
/// `endpoint` already has, and defaults scheme/port when absent.
///
/// Returns `error.MissingHost` (reported via error_handler by the caller,
/// matching the existing parse-failure pattern) rather than panicking when
/// `endpoint` parses but carries no host.
pub fn resolveExportUri(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    signal_path: []const u8, // e.g. "/v1/traces"
) !std.Uri {
    ...
}
```

Path-joining behavior: if `endpoint`'s path is empty or `"/"`, the result is just
`signal_path`. Otherwise the result is `endpoint_path` (trailing slash trimmed) +
`signal_path`, e.g. `"/some/prefix" + "/v1/traces"` → `"/some/prefix/v1/traces"`.
This matches how most OTLP SDKs in other languages already treat a configured base
endpoint's path as a prefix rather than something to be silently discarded.

### 2. Call-site changes

Each of `traces.zig` / `logs.zig` / `metrics.zig`'s `sendRequest` replaces its current
~10-line parse/reformat/reparse block with a single call:

```zig
const full_uri = resolveExportUri(allocator, self.config.endpoint, self.config.protocol_config.traces_path) catch |err| {
    error_handler.reportError(.{
        .component = .exporter,
        .operation = "otlp_url_parsing", // unchanged operation name for consistency with existing dashboards/log greps
        .error_type = .configuration,
        .message = "OTLP trace URL parsing failed",
        .context = self.config.endpoint,
        .source_error = err,
    });
    return err;
};
```

`error.MissingHost` folds into the same `catch` as the existing parse failure — from the
caller's perspective both are "this endpoint config is bad," reported identically.

### 3. Testing

- Unit tests for `resolveExportUri` directly (no HTTP/network involved): bare host+port,
  host+port+existing path, path with/without trailing slash, missing host, missing scheme
  (defaults to http), explicit port vs. default-4318 fallback.
- Existing exporter-level tests (`OtlpTraceExporter basic functionality` etc.) should
  continue to pass unmodified — this is meant to be behavior-preserving for the currently-
  tested no-path case.

## Open questions for review

1. Where should `resolveExportUri` live — `otlp/root.zig` (alongside `OtlpExporterConfig`)
   or a new dedicated file? Leaning dedicated file since it'll carry its own test block and
   isn't really "config," but no strong opinion.
2. Is `"/some/prefix" + "/v1/traces"` the right join semantics, or should a trailing path
   on `endpoint` be an outright rejected/warned-about config (on the theory that OTLP
   collectors don't typically live behind a path prefix, so silently "helping" here might
   mask a genuine misconfiguration)? Current draft assumes append-don't-replace is strictly
   safer than the status quo (silent full replacement) either way, but a reject-and-error
   variant is also defensible.
3. Should the 4318 default become a named constant shared across the three exporters (even
   without full gRPC support) just to kill the literal-4318-in-three-places duplication, or
   is that over-engineering for a value that's unlikely to change soon?
