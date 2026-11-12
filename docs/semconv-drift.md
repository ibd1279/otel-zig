# Semantic-conventions drift audit

Measured 2026-11-12 against the pins introduced in `56fcf82`:
`semantic-conventions` at **v1.45.0**, `semantic-conventions-genai` at `e6658f1`,
compared with the previous baseline **v1.41.0** (the version the `src/semconv/*.zig`
headers cited until this audit).

Reproduce:

```sh
# old model tree (submodule has v1.41.0 fetched but is pinned at v1.45.0)
git -C semantic-conventions worktree add /tmp/sc141 v1.41.0
python3 tools/semconv_audit.py semantic-conventions/model /tmp/sc141/model src/semconv
git -C semantic-conventions worktree remove /tmp/sc141
```

`tools/semconv_audit.py` understands both model shapes: the `groups:`/`- id:`
layout used through v1.43 and the `attributes:`/`- key:` layout
(`file_format: definition/2`) that v1.44+ adopted — **71 of 267 model files are
now in the new format**, so anything that parses the model has to handle both.

## What moved in core semconv (v1.41.0 → v1.45.0)

- attributes: 931 → 1005 (+81 / −7)
- deprecated attributes: 147 → 241
- enum attributes: 165 → 175; metric instruments: 529 → 528
- in-scope additions (namespaces we ship): `http.request.body.content`,
  `http.response.body.content`, `network.local.*` / `network.peer.*`
  (as.number, as.organization, mac.address, prefix), `rpc.request.header`,
  `rpc.response.header`, `rpc.response.trailer`, `rpc.status_code`,
  `server.as.number`, `server.as.organization`, `server.mac.address`,
  `server.prefix`, `server.service.name`, `server.service.namespace`,
  `service.instance.cost_center.{id,name}`, `messaging.kafka.cluster.id`,
  `messaging.system.name`
- enum member additions on enums we ship: `cloud.provider` (+`scaleway_cloud`),
  `cloud.platform` (+`scaleway_cloud_compute`), `telemetry.sdk.language`
  (+`kotlin`), `messaging.system.name` (12 messaging-system values)
- no in-scope attribute was deleted outright

## What moved on us

Of the **249 distinct attribute keys** shipped in `src/semconv/*.zig`
(`metrics.zig` excluded — 23 of 528 metric instruments, all still valid):

**81 keys are deprecated upstream, 79 of them newly since v1.41.0.** Three
different things, which should not be treated the same way:

1. **Relocated, not drifted — 54 keys (`gen_ai.zig` 50, `mcp.zig` 4).**
   Core semconv deprecated `gen_ai.*` and `mcp.*` because they moved to the
   `semantic-conventions-genai` repo, which we pin separately. These names are
   alive there; nothing to do in these files. (`gen_ai.token.type` is the one
   real deprecation in the group: renamed to `output`.)
2. **Real renames — 25 keys** we still ship under the old name:
   - `messaging.zig` (22): `messaging.system` → `messaging.system.name`;
     `messaging.kafka.*` → `kafka.*`; `messaging.gcp_pubsub.*` → `gcp.pubsub.*`;
     `messaging.eventhubs.*` / `messaging.servicebus.*` → `azure.*`;
     `messaging.rabbitmq.*` → `rabbitmq.*`; `messaging.rocketmq.*` → `rocketmq.*`
   - `rpc.zig` (3): `rpc.request.metadata` → `rpc.request.header`,
     `rpc.response.status_code` → `rpc.status_code`,
     `rpc.response.metadata` (deprecated, no replacement recorded)
3. **Obsoleted — 2 keys:** `exception.escaped` (core: `reason: obsoleted` —
   "no longer recommended to record exceptions that are handled and do not
   escape the scope of a span") and `event.name`, both already deprecated at
   v1.41.0 and still shipped.

## Coverage gaps (never implemented, not drift)

Current-and-not-deprecated attributes in namespaces we ship, absent from
`src/semconv`: `resource.zig` 111, `network.zig` 14, `server.zig` 6,
`rpc.zig` 4, `http.zig` 2, `logs.zig` 1, `messaging.zig` 1.

Most of the 111 in `resource.zig` are k8s/container/host attributes we have
never modelled; they are a coverage decision, not drift. The 4 in `rpc.zig`
(`rpc.request.header`, `rpc.response.header`, `rpc.response.trailer`,
`rpc.status_code`) and the 2 in `http.zig` (`http.request.body.content`,
`http.response.body.content`) are small additions.

## The genai repo (second registry)

`semantic-conventions-genai` at `e6658f1`: 102 attributes, 16 model files
(15 in the new format). `gen_ai.zig` ships 59 keys, **0 deprecated**, 38
missing — new surfaces we never modelled: `gen_ai.memory.*`,
`gen_ai.main_agent.*`, `gen_ai.input.messages_ref` / `output.messages_ref`,
`gen_ai.conversation.compacted`, `gen_ai.prompt.variable`. `mcp.zig`'s 8 keys
are all current (its 4 "stale" hits are MCP *metric* names, which this audit
does not compare).

## Organisation

The current shape — 13 hand-written files, keys as plain `pub const` strings,
the submodule as reference-only — is what let 249 constants drift by 25
renames without anything failing. Options, on their real differences:

- **Status quo + this audit run manually.** Zero build cost; drift is only
  found when someone remembers to run it.
- **Build-time codegen (weaver).** `weaver` is not installed here, and the
  semconv repo's own generation runs it from the `otel/weaver` container —
  which this host does not have. It also makes the model format part of the
  build (71/267 files already moved to `definition/2`). High cost for a
  project that already fights generated-code churn.
- **Checked-in registry snapshot + a unit test (recommended).** Commit a
  `semconv_registry.json` produced by `tools/semconv_audit.py`, and add one
  test that asserts every `src/semconv` constant exists in it and none is
  marked deprecated. No new build dependency, no generated Zig to churn,
  drift becomes a failing test instead of a 25-rename surprise. Generated
  typed enums for the handful of enums we actually use would be the natural
  next increment after that.
