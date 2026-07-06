# Status

Lean Beam is alpha code and still mostly a personal experiment. The repository is public for
collaboration and reuse, but it is not yet a polished or stable general-purpose product.

The main product idea is a small, type-safe, isolated execution surface for Lean. Beam is the shared
thin layer on top of Lean LSP plus Beam-specific extensions: the Lean plugin provides the low-level
facts, and the local Beam layer turns those facts into practical CLI, broker, MCP, and skill
workflows.

Alpha compatibility policy lives in [Compatibility Policy](COMPATIBILITY.md).

## Current Scope

### Core Lean Surface

- standalone Lean plugin for `$/lean/runAt`
- internal proof-first, command-fallback basis selection
- typed response payload with messages, traces, optional proof state, and optional follow-up handle
- optional follow-up execution through `$/lean/runWith` and `$/lean/releaseHandle`
- agent-oriented `$/lean/todo` range inspection for actionable items such as sorries, holes,
  diagnostics, code actions, and incomplete proofs, exposed through the broker, `lean-beam todo`,
  and MCP `lean_todo`
- versioned broker/MCP code-action resolution for raw Lean code actions returned by `lean_todo`;
  clients still apply returned LSP workspace edits themselves and then update or sync the file
- small Lean semantic navigation wrappers for hover, signature help, definition, references,
  document symbols, workspace symbols, and mode-based goal inspection, exposed through the broker,
  `lean-beam`, and MCP
- explicit Lean `lean-beam sync` barrier with diagnostics wait and compact `fileProgress` reporting
- zero-build `lean-beam save` checkpoint for one synced workspace module
- typed sync summaries with current diagnostic/readiness counts for the synced document version

### Local Beam Layer

- local Beam daemon/client pair for Lean and Rocq workflows
- optional Rocq Beam goal probes through `coq-lsp`, documented separately in
  [docs/ROCQ.md](ROCQ.md)
- alpha Lean wrapper commands for follow-up handle continuation and release
- installed `lean-beam-search` helper for shorter shell branching/playout workflows
- explicit broker `ok` / `error` response envelopes for machine-readable local protocol consumers,
  while still accepting older inferred-`ok` envelopes on input
- `lean-beam open-files` daemon introspection for tracked documents, including saved/not-saved state,
  direct Lean deps when available, save preflight fields, checkpoint status, and the last compact
  `fileProgress`
- compact `fileProgress` reporting on slow Lean wrapper calls when matching LSP progress
  notifications were observed while the request was pending
- explicit support for installed custom elan-linked Lean toolchains through
  `--custom-toolchain <toolchain>`, recorded in the runtime's `custom-lean-toolchains` registry

### MCP And Agent Integration

- installed experimental `lean-beam-mcp` stdio server exposing the curated Lean Beam tool set through
  MCP `initialize`, `tools/list`, and `tools/call`
- MCP implementation backed directly by the broker runtime rather than by a second daemon/client
  connection
- bug-report identity surfaces: `lean-beam --version`, `lean-beam-mcp --version`, and MCP
  `beam_version` for the running server process, including manifest commit or source checkout
  commit/branch/dirty data
- feedback report-card surfaces: `lean-beam feedback` and MCP `beam_feedback` return structured
  JSON containing pasteable Markdown, metadata, available version/stats/open-file context, daemon
  registry context, and recent daemon incident paths; callers can request a local directory or zip
  evidence bundle
- `lean-beam-mcp --self-check <lean-file>` setup verification for the installed MCP path, root
  setup through `lean_init_workspace`, and a real `lean_sync` tool call
- MCP root discovery through exactly one `roots/list` workspace root, or explicit session setup
  through `lean_init_workspace`
- successful `lean_init_workspace` responses advertise post-initialization MCP capabilities derived
  from the shared operation layer, including `beam_version`, `beam_stats`, `beam_feedback`,
  `lean_update`, `lean_sync`, `lean_refresh`, `lean_save`, `lean_close_save`, `lean_close`,
  `lean_run_at`, `lean_run_at_handle`, `lean_run_with`, `lean_run_with_linear`, `lean_release`,
  `lean_hover`, `lean_signature_help`, `lean_definition`, `lean_references`,
  `lean_document_symbols`, `lean_workspace_symbols`, `lean_goals`, `lean_todo`, and
  `lean_code_action_resolve`
- MCP progress notifications for requests that pass `_meta.progressToken`
- MCP diagnostic log notifications for incremental Lean diagnostics during sync/save-style tools
- MCP `lean_sync` `include_diagnostics` option for clients that need the current request diagnostics
  replayed in the final structured result instead of collecting only interleaved log notifications
- bundled Lean skills for supported agent clients, plus optional Rocq skills when installed with
  `--rocq-skill`

### Coverage

- repo-local regression coverage around isolation, stale state, cancellation, and handle invalidation
- broker, wrapper, install, MCP, and CI coverage described in [docs/TESTING.md](TESTING.md)

## API Notes

### MCP Workspace Initialization

The normal `lean_init_workspace` call supplies only a root:

```json
{"root":"/path/to/lean/project"}
```

The optional `mode` field defaults to `"set"`:

| mode | Behavior |
| --- | --- |
| `"set"` | Initialize the root if unset; succeed idempotently for the active root; reject a different root. |
| `"verify"` | Check that the requested root is already active without changing runtime state. |
| `"reset"` | Explicitly switch roots; discard the current runtime and invalidate handles from the previous root. |

Successful responses include `active_root`, `runtime_reused`, `invalidated_handles`, and a
`capabilities` array naming the projected MCP tools available for the initialized workspace.
`runtime_reused` means no runtime was changed because the requested root was already active;
`reset` always reports `runtime_reused: false`, even when resetting to the same root. Reset
responses also include `previous_root`. Abbreviated example:

```json
{
  "root": "/path/to/other/project",
  "active_root": "/path/to/other/project",
  "previous_root": "/path/to/lean/project",
  "initialized": true,
  "mode": "reset",
  "runtime_reused": false,
  "invalidated_handles": true,
  "capabilities": ["lean_run_at", "lean_sync", "lean_save"]
}
```

### Base Request

The base request is intentionally small:

- one document
- one position
- one Lean command or tactic-block payload
- no required command/tactic mode flag

Request-level failures stay at the transport layer. Semantic Lean outcomes stay in the normal typed
response payload.

### Follow-Up Handles

Follow-up handles exist, but they should be treated as alpha support APIs rather than as a frozen
long-term contract. Current handle behavior is:

- opaque
- document-bound
- invalidated by same-document edits
- invalidated by document close
- invalidated by worker restart or Beam daemon restart
- invalidated by MCP `lean_init_workspace` calls with `mode: "reset"`
- exact continuation requires an explicit handle path; separate `lean-beam run-at` calls do not chain
  through hidden state

### Update, Sync, And Save

Lean position/range/document operations are version-bound across the broker, MCP, and wrapper
surfaces: clients must first update or sync the file and pass the returned document version.
`update` is the cheap version-producing step; `sync` is for clients that also need
diagnostics/readiness. Workspace symbol queries are workspace-scoped and do not take a file
version.
Broker-detected stale-version failures use `contentModified` with
`error.data.reason = "documentVersionMismatch"` and include the currently accepted document version
when available.

`lean-beam update`, `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` should be read as
a progression:

- `lean-beam update` opens or updates the broker's LSP mirror and returns the current document
  version without waiting for diagnostics
- `lean-beam sync` establishes the diagnostics-complete saved file snapshot for the current document
  version
- `lean-beam save` checkpoints that snapshot for one module
- `lean-beam close-save` does the same checkpoint and then closes the tracked file

By default, `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` stream only errors for the
current request; `+full` widens that stream to warnings, info, and hints. The final stdout JSON
reports compact summary fields rather than replaying the full LSP notification stream.

The final sync result reports the current synced document state under save-readiness semantics:
`errorCount` is the current save-blocking frontend error count, `warningCount` is the current
warning count, and `saveReady` / `stateErrorCount` / `stateCommandErrorCount` describe whether the
save/checkpoint path should proceed. Successful sync responses also include `result.syncSummary`,
with `currentVersion` and current diagnostic/readiness counts. New machine consumers should prefer
`result.syncSummary.readiness.current.saveReady` and `errorCount` for checkpoint decisions. The
canonical field-level contract lives in [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md).

`lean-beam save` includes the sync verdict it established before checkpointing in `result.sync`;
`lean-beam close-save` includes the same verdict in `result.saved.sync`. Document-error save
failures include that verdict in `error.data.sync`, so clients can inspect the synced version and
save-readiness decision that blocked checkpointing.

If Lean cannot reach a completed diagnostics barrier for the synced version, for example because an
imported target is stale and rebuild failure kills the worker session, `lean-beam sync` fails rather
than reporting partial success. `lean-beam save` and `lean-beam close-save` refuse to proceed past
that incomplete barrier.

Lean sync failures may attach a cheap direct-import recovery hint in `error.data`; the CLI mirrors
that recovery plan on stderr for human-facing `lean-beam sync` / `lean-beam save` paths while
keeping stdout as machine-readable JSON. The hint includes
`staleDirectDeps`, `saveDeps`, and `recoveryPlan`. This suggests `save` / `refresh` / `lake build`
next steps without running a full workspace dependency scan.
Failures may also include `error.data.completionBlockingDiagnostics`; those entries carry
`completionBlocking=true` because the file could not reach the diagnostics-complete barrier.

`lean-beam save` is module-oriented, not file-oriented. `lean-beam sync` can operate on an arbitrary
file the daemon can open, but `lean-beam save` requires a file that Lake resolves to a module in the
current workspace package graph. Save target resolution loads the real Lake workspace configuration
and does not infer package or module declarations by parsing `lakefile.lean` text in the broker.
Standalone `.lean` files outside that graph are not valid save targets.

The zero-build save path is also restricted to Lake module setups that can be replayed from the LSP
snapshot without custom batch setup. Modules whose Lake setup uses custom Lean options, Lean
arguments, dynamic libraries, or plugins fail with `saveUnsupportedSetup`; use `lake build` for
those modules.

If a speculative probe looks right and should become real source, the current contract is still:
make the real edit in the file, save it, then run `lean-beam sync`. The intended future direction is
to make that handoff cheap by reusing speculative execution rather than replaying it from scratch.

### Local Protocol

For programmatic local consumers, the preferred machine-readable surface is the JSON stream exposed
by `beam-client request-stream`; wrapper stderr should be treated as human-facing. Broker responses
require an explicit top-level `ok` boolean, giving projection layers an unambiguous success/error
discriminator.

### MCP

`lean-beam-mcp` is an experimental stdio entry point. The installed wrapper is the preferred setup
path because it passes the matching `beam-cli` resolver automatically. `--root PATH` is supported as
an explicit override. When it is omitted, clients should either call `lean_init_workspace` with one
absolute Lean/Lake project root before other Lean tools, or advertise exactly one `file://` project
root through MCP `roots/list`. Multiple roots are rejected for now. Direct developer runs of
`.lake/build/bin/lean-beam-mcp` can still pass `--lean-cmd` and `--lean-plugin` explicitly.

Current MCP implementation, protocol, and conformance notes live in [docs/MCP.md](MCP.md).

### Progress And Sync Reporting

Progress, diagnostics, and readiness are separate typed concepts:

| Concept | Scope | Current surface |
| --- | --- | --- |
| Progress | Request-scoped operation movement, not diagnostics and not final readiness. | MCP `notifications/progress`; Beam stream `progress` events; CLI progress text. |
| Streamed diagnostics | Lean-published events observed while a request is pending. | MCP `notifications/message` with logger `lean.diagnostic`; Beam stream `diagnostic` events; CLI stderr diagnostics. |
| Current summary | Stable synced-state verdict for one document version. | Final structured tool result and broker response fields such as `saveReady`, `errorCount`, and `file_progress`. |

The canonical field-level contract lives in
[SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md). This status document summarizes the current
shape and release posture; use the contract document for exact sync, save, progress, diagnostic
replay, readiness, and delta semantics.

For MCP, Beam forwards incremental Lean diagnostics as structured `notifications/message` log
events with path, URI, version, range, severity, message data, and `completionBlocking=true` when
the diagnostic is known to block file completion. Streamed diagnostics remain request-scoped
observations; save-readiness evidence is attached to the final sync/save verdict instead of being
retroactively added to earlier stream events. These diagnostics are deliberately not encoded as
progress. As an MCP compatibility path, `lean_sync` also accepts `include_diagnostics: true` to
replay the current request diagnostics under `structuredContent.diagnostics`; the
`full_diagnostics` option controls whether that replay uses the default error-only filter or includes
warnings, information, and hints too. Beam also parses tool-call `_meta.progressToken` and emits
`notifications/progress` for request-scoped setup and execution phases, plus throttled Lean
`fileProgress.line` / `totalLines` / `updates` / `done` details, before the final JSON-RPC response.
The numeric `progress` value is a per-request monotonic sequence.

Diagnostic severity and save readiness intentionally answer different questions. Use
`diagnostics.current.error` for Lean-published error-severity diagnostics. Use
`readiness.current.errorCount` and `readiness.current.saveReady` for the save/checkpoint decision.
Current error-severity diagnostics force a not-ready verdict for the synced version; warnings,
information, and hints do not block saving by themselves.

Beam save-readiness follows Lean batch/Lake's artifact gate for the current synced snapshot:
current save-blocking frontend errors block saving. Diagnostic streams, diagnostic summaries, and
message history are observations; clients should not reconstruct save readiness from them.

Each `syncSummary` describes only the current synced document version. It does not carry deltas
against previous responses; clients that need comparisons should retain the previous response they
care about and compare it explicitly.

## Known Limitations

### Toolchains And Bundles

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading is toolchain-keyed, not toolchain-agnostic.
- Supported Lean toolchains are listed in
  [supported-lean-toolchains](../supported-lean-toolchains).
- The supported fast path is the Lean toolchain pinned by this repository's `lean-toolchain`, because
  the plugin uses internal Lean APIs.
- The install script prebuilds an installed-skill bundle cache for that pinned toolchain by default.
- The install script also accepts `--toolchain <toolchain>` for explicit supported bundles and
  `--all-supported` for the full validated allowlist.
- The install script accepts `--custom-toolchain <toolchain>` for explicit elan-linked local Lean
  development toolchains. These names are recorded in the installed runtime's
  `custom-lean-toolchains` registry and are accepted but not validated release targets.
- Installer locations, MCP registration paths, supported/custom toolchain prebuilds, and
  slow/offline setup are documented in [SETUP.md](SETUP.md).
- Runtime requests first try that installed-skill bundle cache, then fall back to a project-local
  runtime bundle under `.beam/bundles/` for supported or explicitly custom toolchains.
- Unsupported Lean toolchains that are not explicitly custom fail early instead of attempting an
  opportunistic build.
- `lean-beam supported-toolchains` lists the validated toolchains, and `lean-beam doctor` reports
  validated support state, custom acceptance state, bundle source, and bundle key inputs.
- Bundle rebuild keys intentionally exclude the full `.lake/packages` checkout tree and instead use
  the resolved toolchain fingerprint, the runtime source tree, `lean-toolchain`,
  `lake-manifest.json`, and `supported-lean-toolchains` / `custom-lean-toolchains`. See
  [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the custom toolchain and runtime-bundle model.
- The first use of a supported or explicitly custom but not-yet-prebuilt toolchain must still build
  a matching local fallback bundle.
- On a cold machine, that local fallback build may need network access to fetch dependencies.

### Runtime And Sandbox Behavior

- In sandboxed agent environments, Beam daemon startup itself may require elevated permissions even
  when the installed bundle and project-local `.beam` paths resolve correctly.
- A startup failure that reports `operation not permitted` through `.beam/beam-daemon-startup.log` is
  usually an environment restriction, not a bundle-resolution mismatch.
- Beam daemon disappearance errors include registry/log context and write a JSON incident record under
  `.beam/daemon-failures/` or the per-root subdirectory of `BEAM_CONTROL_DIR`. Beam keeps the latest
  50 incident records and `lean-beam doctor` lists recent incident paths.
- Cancellation is cooperative; prompt stopping depends on inner elaboration polling interruption.
- The Beam daemon is single-root and keeps a conservative single active session per backend.

### MCP

- `lean-beam-mcp` currently advertises MCP protocol revision `2025-11-25` only. Older revisions are
  not advertised or tested.
- `lean-beam-mcp` follows the `2025-11-25` tool-call error split: malformed or unknown tools are
  JSON-RPC protocol errors, while invalid inputs for known tools return MCP tool execution errors
  with `isError=true`.
- MCP workspace reset invalidates handles minted by the old runtime; discard saved handle files
  after `lean_init_workspace` with `mode: "reset"`.
- `lean-beam-mcp` emits live MCP progress notifications for tool calls that include
  `_meta.progressToken`, forwards incremental Lean diagnostics as MCP log notifications, and still
  leaves MCP cancellation notifications as future work.
- The Streamable HTTP bridge is test-only; the product entry point remains stdio.

### Sync, Save, And Staleness

- Zero-build `lean-beam save` helps checkpoint one module, but it is not a whole-workspace freshness
  solution.
- If you edit a dependency of the target file, downstream speculative results should be treated as
  stale until rebuild or checkpoint.
- For open files in Lake workspaces, Beam uses Lean's native stale-dependency diagnostic when a synced
  source change makes an importer need refresh. Beam does not yet implement Lean's dynamic watched-file
  registration, so external source changes that never pass through `sync` remain outside the current
  watcher surface.
- `error.data.staleDirectDeps` recovery hints are still broker-derived metadata. Beam currently
  uses direct imports returned by Beam's diagnostics barrier request from Lean's accepted header
  snapshot and combines those imports with broker sync/save history to infer stale direct
  dependencies and `needsSave`. The planned Lean-side backlog item is to expose structured
  stale-dependency metadata from Lean's watchdog/file-worker
  path, so Beam can derive these hints from Lean instead of duplicating that state in the broker.

### Distribution And Rocq

- Agent-skill distribution currently relies on a local checkout and local install script; it is not
  yet published through a registry or marketplace flow.
- Rocq support is currently limited to goal inspection through `coq-lsp`; it is not yet a full
  stateful execution layer.

## Direction

Near-term work is mostly about hardening and simplifying:

- keep the base `runAt` request small
- preserve strict per-request isolation
- reduce packaging and workspace rough edges
- publish a smoother distribution path, likely GitHub-backed install for Codex and plugin
  marketplace packaging for Claude
- improve stale-dependency handling, especially by moving structured stale-dependency metadata into
  Lean's native stale-dependency signal instead of broker-side reconstruction
- upstream structured JSON-RPC error data for Lean request failures, so plugin-level
  `contentModified` errors can carry machine-readable recovery fields such as
  `documentVersionMismatch` without requiring broker-side preflight rejection
- replace broker-side diagnostics/fileProgress barrier inference with a stronger backend-facing
  readiness primitive, so `lean-beam sync` / `lean-beam save` can trust one authoritative completion
  signal instead of reconstructing barrier completeness from multiple LSP channels
- track an upstream Lean API improvement for a pure frontend readiness/reporting helper, close to
  `SnapshotTree.runAndReport` but returning the build-blocking decision and message counts without
  printing
- add richer MCP progress percentages or bounded work-unit totals if Lean exposes them; keep
  structured MCP log messages for incremental diagnostics rather than overloading progress
  notifications or the final tool result
- keep the `sync`, `save`, and `close-save` summary projections aligned as the sync-summary schema
  evolves
- keep Beam-daemon-side conveniences useful without turning them into a large public surface too early
- add a short comparison against Pantograph in the docs, to clarify where `runAt` fits among nearby Lean tooling
- keep cross-surface utility code such as root resolution and workspace-relative path derivation in
  shared Beam modules, not copied across CLI, broker, MCP, and test helpers

## Release Focus

The first Lean release should stay conservative:

- keep the current `runAt`, `lean-beam`, and MCP surfaces small and documented
- keep CLI and MCP as thin projections over shared typed operation adapters
- keep supported Lean-toolchain and install behavior covered in CI
- take stability fixes when they materially improve release confidence
- defer broader dependency/readiness redesigns until Lean or Lake expose stronger primitives
