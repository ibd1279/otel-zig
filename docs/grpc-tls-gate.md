# OTLP/gRPC-over-TLS e2e gate (authored by the implementer, EXECUTED BY THE OPERATOR)

The local Datadog agent's OTLP/gRPC listener currently runs plaintext h2c on
`localhost:4317` (datadog.yaml:
`otlp_config.receiver.protocols.grpc.endpoint`). This gate switches that
receiver to TLS with a self-signed certificate, points the otel-zig
exporter's CA bundle at it, and re-runs the three OTLP example steps over
gRPC.

Everything below that needs privileges is yours to run (sudo). Nothing in
this repo touches `/opt/datadog-agent`.

## 1. Generate a self-signed cert/key pair

```sh
sudo security create-certificate -c localhost \
  -a /etc/datadog-agent/grpc-tls-key.pem \
  /etc/datadog-agent/grpc-tls-cert.pem
```

If `security create-certificate` is unavailable on your macOS, the
equivalent openssl form is:

```sh
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=localhost" \
  -keyout /etc/datadog-agent/grpc-tls-key.pem \
  -out /etc/datadog-agent/grpc-tls-cert.pem
sudo chown dd-agent:dd-agent /etc/datadog-agent/grpc-tls-cert.pem /etc/datadog-agent/grpc-tls-key.pem
```

(Note: the agent runs as the `dd-agent` user; the files must be readable by
it.)

## 2. datadog.yaml change — exact block to hand to the receiver config

Under `/opt/datadog-agent/etc/datadog.yaml`, extend the existing
`otlp_config` block so the gRPC receiver protocol section reads:

```yaml
otlp_config:
  receiver:
    protocols:
      grpc:
        endpoint: "localhost:4317"
        transport: tcp
        tls:
          cert_file: /etc/datadog-agent/grpc-tls-cert.pem
          key_file: /etc/datadog-agent/grpc-tls-key.pem
```

(Keep whatever else `otlp_config` already sets, e.g. the `http` protocol
section; only the `grpc` subsection gains `tls`.)

## 3. Client-side change

Point the exporter's CA bundle at the self-signed cert. The examples read
`OTEL_EXPORTER_OTLP_PROTOCOL`; for the TLS run, additionally point
`tls_config.ca_file` at the cert. Concretely, in the three example files
(`examples/simple_trace_otlp.zig`, `examples/metrics_histogram_otlp.zig`,
`examples/dns_query_std_log_otlp.zig`) extend the grpc branch of
`exporter_config` with:

```zig
.tls_config = .{ .ca_file = "/etc/datadog-agent/grpc-tls-cert.pem" },
```

(or export `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` and pass the CA path through
your own config path if you wire the examples differently). For the TLS gate the endpoint must be `https://localhost:4317`
(`.endpoint = "https://localhost:4317"`) so the gRPC backend takes its
ALPN-h2 TLS path with the configured `ca_file`; the plaintext `http` scheme
only applies to the non-TLS runs.

## 4. Restart the agent (operator, requires sudo)

```sh
sudo launchctl kickstart -k system/com.datadoghq.agent
```

## 5. Re-run the e2e gate over TLS

```sh
cd /Users/nessa/Documents/zig/otel-zig/.worktrees/t_35baa2b8
for step in example-simple-trace-otlp example-metrics-otlp example-dns-query-std-log-otlp; do
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc zig build -Dotlp-httpx "$step"
done
```

Then verify receipts:

```sh
tail -50 /opt/datadog-agent/logs/agent.log | grep -E "resource (spans|metrics|logs)"
```

Expected shapes (same as the plaintext gate already recorded on 2026-10-22):
`resource spans:1,spans:1`, `resource metrics:1,metrics:33,data points:33`,
`resource logs:1,log records:1`.

## 6. Roll back

Remove the `tls:` block from the `grpc` protocol section, restart the agent
with the same kickstart command, and drop the `.tls_config` line from the
examples.
