# Status

Lean Beam is experimental beta software. The repository is public for collaboration, early use, and
feedback, but interfaces and installation details may still change before a stable release.

This page is the public scope and limitation summary. It should answer "what can I rely on today?"
without becoming a second protocol reference. Exact setup instructions live in [SETUP.md](SETUP.md);
exact MCP behavior lives in [MCP.md](MCP.md); exact sync, save, progress, and diagnostic behavior
lives in [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md). The pre-stable compatibility policy
lives in [Compatibility Policy](COMPATIBILITY.md).

The main product idea remains small: run speculative Lean text at a saved file position without
mutating the user's real document state. The conceptual request is still:

```text
runAt(pos, "lean text")
```

Beam adds a thin local layer around Lean LSP plus Beam-specific Lean extensions. The Lean plugin
provides low-level facts; the local Beam layer exposes those facts through the `lean-beam` CLI,
broker runtime, MCP server, and installed agent skills.

## Current Scope

### Core Lean Surface

Currently supported:

- speculative Lean execution through `$/lean/runAt`, exposed as `lean-beam run-at` and MCP
  `lean_run_at`
- internal proof-first, command-fallback basis selection with no public mode flag
- typed responses containing messages, traces, optional proof state, and optional follow-up handles
- follow-up handle execution through `$/lean/runWith`, `$/lean/releaseHandle`, wrapper commands, and
  matching MCP tools
- actionable file inspection through `$/lean/todo`, `lean-beam todo`, and MCP `lean_todo`
- selected Lean/LSP-style navigation through the same wrapper and MCP projections: hover, signature
  help, definitions, references, document/workspace symbols, and goal inspection
- explicit saved-file synchronization through `lean-beam update`, `lean-beam sync`,
  `lean-beam save`, and `lean-beam close-save`

The base `runAt` path is the main API story. Follow-up handles and search helpers are useful
pre-stable extensions, but they are not the center of the product contract.

### CLI, Broker, And Runtime

The normal human and agent entry point is the installed `lean-beam` wrapper. The wrapper talks to a
local Beam broker/runtime that owns the Lean session for one project root and reports structured JSON
for machine consumers.

The wrapper currently supports:

- project-root discovery through the current directory or `--root`
- supported-toolchain and runtime-bundle diagnostics through `lean-beam doctor`
- saved-file update/sync/run-at/todo/navigation/save commands
- daemon inspection through `lean-beam open-files` and `lean-beam stats`
- structured feedback report cards through `lean-beam feedback`

Programmatic local consumers should prefer the broker JSON stream exposed by
`beam-client request-stream`. Wrapper stderr is human-facing and may change as diagnostic text
improves.

### MCP And Agent Integration

The installed `lean-beam-mcp` server is an experimental stdio MCP projection over the same Beam
operation layer. It is not a raw Lean LSP proxy and does not expose arbitrary LSP methods.

Currently supported:

- workspace setup through exactly one MCP roots result, an explicit `--root`, or
  `lean_init_workspace`
- projected Lean tools for update, sync, run-at, handles, navigation, todo/code-action resolution,
  save, close, and workspace symbols
- utility tools such as `beam_version`, `beam_stats`, and `beam_feedback`
- progress notifications for tool calls with `_meta.progressToken`
- diagnostic log notifications for sync/save-style requests
- `lean-beam-mcp --self-check <lean-file>` for installed-path setup verification
- bundled Lean skills for supported agent clients, with optional Rocq skills when installed with
  `--rocq-skill`

The generated MCP tool list and client semantics are documented in [MCP.md](MCP.md).

### Rocq Surface

Rocq support is intentionally narrow. Beam can expose optional goal probes through `coq-lsp`, mainly
for Rocq-to-Lean porting workflows. It is not a Rocq analogue of the Lean speculative execution
layer. Rocq setup and workflow details live in [ROCQ.md](ROCQ.md).

## Current Contracts

### Request Isolation

Each speculative Lean request should behave like an isolated sandbox:

- it must not mutate the document's real elaboration state
- it must not rely on side effects from previous speculative requests
- it must not leak hidden mutable state through the base API
- continuation state is kept only when the caller explicitly asks for a follow-up handle

### Saved Files And Versions

Beam operates on saved files, not unsaved editor buffers. Position and range operations are
version-bound: callers update or sync a file, then pass the returned document version to later
probes. If Beam reports `contentModified`, update or sync again and retry with the accepted current
version.

`lean-beam sync` is the diagnostics/readiness barrier after a real saved edit. `lean-beam save`
adds a zero-build checkpoint for one synced Lake module. `lean-beam close-save` checkpoints and then
closes the tracked file. The exact fields and failure shapes live in
[SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md).

### Compatibility

During beta, compatibility is intentionally narrow. Supported Lean toolchains, runtime-bundle
metadata, install-layout metadata, the advertised MCP protocol revision, and explicitly documented
client requirements are the named compatibility targets. CLI and MCP surfaces are discoverable
through help text, installed skill text, and MCP `tools/list`; during beta, that discovery is the
compatibility story for those surfaces. See [COMPATIBILITY.md](COMPATIBILITY.md).

## Known Limitations

### Toolchains And Distribution

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading is toolchain-keyed, not toolchain-agnostic.
- Supported Lean toolchains are listed in
  [supported-lean-toolchains](../supported-lean-toolchains).
- The installer prebuilds the repository-pinned supported toolchain by default and can prebuild
  additional supported or explicitly custom toolchains.
- Runtime requests first try the installed bundle cache, then fall back to a project-local runtime
  bundle under `.beam/bundles/`.
- Unsupported Lean toolchains that are not explicitly custom fail early instead of attempting an
  opportunistic build.
- First use of a supported or custom but not-yet-prebuilt toolchain may need to build a local
  fallback bundle. On a cold machine, that build may need network access.
- Agent-skill distribution currently relies on a local checkout and install script; it is not yet
  published through a registry or marketplace flow.

### Runtime And Sandbox Behavior

- In sandboxed agent environments, Beam daemon startup can require elevated permissions even when
  the installed bundle and project-local `.beam` paths resolve correctly.
- A startup failure that reports `operation not permitted` through `.beam/beam-daemon-startup.log`
  is usually an environment restriction, not a bundle-resolution mismatch.
- The Beam daemon is single-root and keeps a conservative single active session per backend.
- Cancellation is cooperative; prompt stopping depends on inner elaboration polling interruption.
- Beam daemon disappearance errors include registry/log context and write a JSON incident record
  under `.beam/daemon-failures/` or the per-root subdirectory of `BEAM_CONTROL_DIR`.

### MCP

- `lean-beam-mcp` currently advertises MCP protocol revision `2025-11-25` only. Older revisions are
  not advertised or tested.
- MCP workspace reset invalidates handles minted by the old runtime.
- MCP cancellation notifications are not implemented yet.
- The Streamable HTTP bridge is test-only; the product entry point is stdio.

### Sync, Save, And Staleness

- Zero-build `lean-beam save` checkpoints one module; it is not a whole-workspace freshness
  solution.
- If you edit a dependency of the target file, downstream speculative results should be treated as
  stale until rebuild or checkpoint.
- Beam uses Lean's native stale-dependency diagnostic for open importers when a synced source edit
  makes them need refresh.
- Beam does not yet implement Lean's dynamic watched-file registration, so external source changes
  that never pass through `sync` are outside the current watcher surface.
- Some stale-dependency recovery hints are still broker-derived metadata. The intended backend
  improvement is to expose structured stale-dependency metadata from Lean's native
  watchdog/file-worker path.

### Rocq

- Rocq support is limited to goal inspection through `coq-lsp`.
- Rocq does not currently expose an equivalent public sync/save/speculative execution layer through
  Beam.

## Beta Direction

Near-term work should harden the small public surface rather than expand it broadly:

- keep the base `runAt` request small
- preserve strict per-request isolation
- keep CLI and MCP as thin projections over shared typed operation adapters
- reduce packaging, install, and workspace rough edges
- improve stale-dependency handling by moving more metadata into Lean's native stale-dependency
  signal
- replace broker-side diagnostics/fileProgress barrier inference with a stronger backend-facing
  readiness primitive when Lean or Lake expose one
- keep Beam-daemon conveniences useful without turning them into a large public surface too early
- document comparisons with nearby Lean tooling, including where `runAt` differs from Pantograph
- keep root resolution, workspace-relative paths, and similar cross-surface utility code in shared
  Beam modules instead of copying it across CLI, broker, MCP, and test helpers
