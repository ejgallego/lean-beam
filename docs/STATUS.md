# Status

Lean Beam is experimental alpha software. The repository is public for collaboration, early use,
and feedback, but interfaces and installation details may still change before a stable release.

The main product idea is a small, type-safe, isolated execution surface for Lean. Beam is the shared
thin layer on top of Lean LSP plus Beam-specific extensions: the Lean plugin provides low-level
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
  JSON containing pasteable Markdown, metadata, collection warnings, and optional evidence bundle
  paths; CLI output and MCP `include_collected: true` include collected version/stats/open-file
  context, daemon registry context, and recent daemon incident paths
- `lean-beam-mcp --self-check <lean-file>` setup verification for the installed MCP path, root
  setup through `lean_init_workspace`, and a real `lean_sync` tool call
- MCP root discovery through exactly one `roots/list` workspace root, explicit `--root`, or explicit
  session setup through `lean_init_workspace`
- projected MCP tools for versioned Lean file operations, semantic navigation, todo/code-action
  workflows, follow-up handles, save/sync operations, version/stats, and feedback report cards; the
  generated tool list and client semantics are documented in [MCP.md](MCP.md)
- MCP progress notifications for requests that pass `_meta.progressToken`
- MCP diagnostic log notifications for incremental Lean diagnostics during sync/save-style tools
- MCP `lean_sync` `include_diagnostics` option for clients that need the current request diagnostics
  replayed in the final structured result instead of collecting only interleaved log notifications
- bundled Lean skills for supported agent clients, plus optional Rocq skills when installed with
  `--rocq-skill`

### Coverage
- repo-local regression coverage around isolation, stale state, cancellation, and handle invalidation
- broker, wrapper, install, MCP, and CI coverage described in [docs/TESTING.md](TESTING.md)

## Operational Notes

The base request remains intentionally small:

- one document
- one position
- one Lean command or tactic-block payload
- no required command/tactic mode flag

Request-level failures stay at the transport layer. Semantic Lean outcomes stay in the normal typed
response payload.

Follow-up handles exist, but they should be treated as alpha support APIs rather than as a frozen
long-term contract. They are opaque, document-bound, invalidated by same-document edits, document
close, worker or daemon restart, and MCP workspace reset. Exact continuation requires an explicit
handle path; separate `lean-beam run-at` calls do not chain through hidden state.

The `lean-beam update`, `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` commands are
a progression:

- `lean-beam update` opens or updates the broker's LSP mirror and returns the current document
  version without waiting for diagnostics
- `lean-beam sync` establishes the diagnostics-complete saved file snapshot for the current document
  version
- `lean-beam save` checkpoints that snapshot for one module
- `lean-beam close-save` does the same checkpoint and then closes the tracked file

Position/range/document operations are version-bound across the broker, MCP, and wrapper surfaces.
Clients first update or sync a saved file, then pass the returned document version to later probes.
Workspace symbol queries are workspace-scoped and do not take a file version. The canonical
field-level contract for update, sync, save, progress, diagnostics, stale-version failures,
readiness, and recovery hints lives in [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md).

If a speculative probe looks right and should become real source, the current contract is still:
make the real edit in the file, save it, then run `lean-beam sync`. The intended future direction is
to make that handoff cheap by reusing speculative execution rather than replaying it from scratch.

For programmatic local consumers, the preferred machine-readable surface is the JSON stream exposed
by `beam-client request-stream`; wrapper stderr should be treated as human-facing. Broker responses
require an explicit top-level `ok` boolean, giving projection layers an unambiguous success/error
discriminator.

`lean-beam-mcp` is the experimental stdio MCP entry point. User setup lives in
[SETUP.md](SETUP.md#mcp-setup); implementation, protocol, tool-list, and conformance notes live in
[MCP.md](MCP.md).

## Known Limitations

### Toolchains And Bundles

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading is toolchain-keyed, not toolchain-agnostic.
- Supported Lean toolchains are listed in
  [supported-lean-toolchains](../supported-lean-toolchains).
- The supported fast path is the Lean toolchain pinned by this repository's `lean-toolchain`, because
  the plugin uses internal Lean APIs.
- The installer prebuilds the pinned supported toolchain by default and can prebuild additional
  supported or explicitly custom toolchains; setup flags and offline notes live in
  [SETUP.md](SETUP.md).
- Runtime requests first try that installed-skill bundle cache, then fall back to a project-local
  runtime bundle under `.beam/bundles/` for supported or explicitly custom toolchains.
- Unsupported Lean toolchains that are not explicitly custom fail early instead of attempting an
  opportunistic build.
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
- MCP workspace reset invalidates handles minted by the old runtime; discard saved handle files
  after `lean_init_workspace` with `mode: "reset"`.
- `lean-beam-mcp` emits live MCP progress notifications for tool calls that include
  `_meta.progressToken`, forwards incremental Lean diagnostics as MCP log notifications, and still
  leaves MCP cancellation notifications as future work.
- The Streamable HTTP bridge is test-only; the product entry point remains stdio.
- Exact protocol behavior and conformance notes live in [MCP.md](MCP.md).

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

## First Alpha Release Focus

The first public Lean release should stay conservative:

- keep the current `runAt`, `lean-beam`, and MCP surfaces small and documented
- keep CLI and MCP as thin projections over shared typed operation adapters
- keep supported Lean-toolchain and install behavior covered in CI
- take stability fixes when they materially improve release confidence
- defer broader dependency/readiness redesigns until Lean or Lake expose stronger primitives
