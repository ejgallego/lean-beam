# Status

Lean Beam is alpha code and still mostly a personal experiment.

The repository is public for collaboration and reuse, but it is not yet a polished or stable
general-purpose product. The main goal is still a small, type-safe, isolated execution surface for
Lean, with a thin local Beam daemon around it for low-cost experimentation.

Alpha compatibility policy lives in [Compatibility Policy](COMPATIBILITY.md).

## Current Scope

- standalone Lean plugin for `$/lean/runAt`
- internal proof-first, command-fallback basis selection
- typed response payload with messages, traces, optional proof state, and optional follow-up handle
- optional follow-up execution through `$/lean/runWith` and `$/lean/releaseHandle`
- agent-oriented `$/lean/todo` range inspection for actionable items such as sorries, holes,
  diagnostics, code actions, and incomplete proofs, exposed through the broker, `lean-beam todo`,
  and MCP `lean_todo`
- small Lean semantic navigation wrappers for hover, signature help, definition, references,
  document symbols, workspace symbols, and mode-based goal inspection, exposed through the broker,
  `lean-beam`, and MCP
- local Beam daemon/client pair for Lean workflows
- optional Rocq Beam goal probes through `coq-lsp`, documented separately in
  [docs/ROCQ.md](ROCQ.md)
- alpha Lean wrapper commands for follow-up handle continuation and release
- installed `lean-beam-search` helper for shorter shell branching/playout workflows
- explicit broker `ok` / `error` response envelopes for machine-readable local protocol consumers
- installed experimental `lean-beam-mcp` stdio server exposing the curated Lean Beam tool set through
  MCP `initialize`, `tools/list`, and `tools/call`, backed directly by the broker runtime rather
  than a second daemon/client connection
- bug-report identity surfaces: `lean-beam --version`, `lean-beam-mcp --version`, and MCP
  `beam_version` for the running server process, including manifest commit or source checkout
  commit/branch/dirty data
- MCP `lean_sync` `include_diagnostics` option for clients that need sync diagnostics replayed in
  the final structured tool result instead of collecting only interleaved log notifications
- MCP `lean_init_workspace` setup tool for clients that can register only a generic global server
  command and do not advertise MCP roots. It requires an absolute Lean/Lake project root and keeps
  root switching explicit, and successful results advertise the projected MCP capability names; see
  [MCP Workspace Initialization](#mcp-workspace-initialization).
- `lean-beam-mcp --self-check <lean-file>` setup verification for the installed MCP path, explicit
  `lean_init_workspace` runtime setup, and a real `lean_sync` tool call
- explicit Lean `lean-beam sync` Beam-daemon barrier with diagnostics wait and compact `fileProgress` reporting
- `lean-beam open-files` Beam-daemon introspection for tracked documents, including `saved` / `notSaved`,
  whether the current synced version has been checkpointed with `lean-beam save`, and Lean save
  preflight fields `saveEligible` / `saveReason` / `saveModule`;
  already-known tracked files are checked incrementally against the on-disk text and carry the last
  observed compact `fileProgress`
- compact Lean Beam-daemon `fileProgress` reporting on other slow Lean wrapper calls when matching
  `$/lean/fileProgress` notifications were observed while the request was pending
- repo-local regression coverage around isolation, stale state, cancellation, and handle invalidation

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

Successful responses include `active_root`, `runtime_reused`, and `invalidated_handles`.
`runtime_reused` means no runtime was changed because the requested root was already active;
`reset` always reports `runtime_reused: false`, even when resetting to the same root. Reset
responses also include `previous_root`:

```json
{
  "root": "/path/to/other/project",
  "active_root": "/path/to/other/project",
  "previous_root": "/path/to/lean/project",
  "initialized": true,
  "mode": "reset",
  "runtime_reused": false,
  "invalidated_handles": true
}
```

The base request is intentionally small:

- one document
- one position
- one Lean command or tactic-block payload
- no required command/tactic mode flag

Request-level failures stay at the transport layer. Semantic Lean outcomes stay in the normal typed
response payload.

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

The local Beam daemon convenience layer is also still alpha. `lean-beam update` is the supported
cheap on-disk edit observation for Lean files: it opens or updates the broker's LSP mirror and
returns the broker-owned document version without waiting for diagnostics. `lean-beam sync` is the
supported diagnostics/readiness barrier: it waits for diagnostics for the current document version,
streams fresh request diagnostics, and returns an ordered machine-readable JSON verdict on stdout.
By default `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` stream only errors for the
current request; `+full` widens that stream to warnings, info, and hints. The detailed progress,
diagnostics, save-readiness, and sync contract lives in
[Sync And Diagnostics Contract](SYNC_AND_DIAGNOSTICS.md). For programmatic local consumers, the
preferred machine-readable surface is the JSON stream exposed by `beam-client request-stream`; the
wrapper stderr format should be treated as human-facing.

Lean position/range/document operations are version-bound across the broker, MCP, and wrapper
surfaces: clients must first update or sync the file and pass the returned document version.
`update` is the cheap version-producing step; `sync` is for clients that also need
diagnostics/readiness. Workspace symbol queries are workspace-scoped and do not take a file
version.
Broker-detected stale-version failures use `contentModified` with
`error.data.reason = "documentVersionMismatch"` and include the currently accepted document version
when available.

Beam broker responses require an explicit top-level `ok` boolean, giving projection layers an
unambiguous success/error discriminator.
Other slow Lean Beam daemon calls may attach a compact top-level `fileProgress` summary when they
had to wait on the same Lean elaboration progress. That is observability except where `sync`,
`save`, and `close-save` explicitly use it as a diagnostics-completion barrier input. MCP setup
progress is separate from Lean-file sync latency.
The wrapper now also exposes alpha Lean handle commands for
continuation, linear playout, and release; these are useful for search-style workflows but are still
more fragile than the base one-shot request. Optional Rocq support remains goals-only and does not
currently expose an equivalent public sync command in the wrapper.

If Lean cannot reach a completed diagnostics barrier for the synced version, for example because an
imported target is stale and rebuild failure kills the worker session, `lean-beam sync` now fails rather
than reporting a partial success. `lean-beam save` and `lean-beam close-save` refuse to proceed past that
incomplete barrier. Lean sync failures may also attach a cheap direct-import recovery hint in
`error.data`, based on broker-tracked saved dependency boundaries, to suggest `save` / `refresh` /
`lake build` next steps without running a full workspace dependency scan. These failures may include
`error.data.completionBlockingDiagnostics` entries with `completionBlocking=true` when a diagnostic
explains why the requested file could not reach a diagnostics-complete barrier. The CLI mirrors that
recovery plan on stderr for the human-facing `lean-beam sync` / `lean-beam save` paths while keeping
stdout as the machine-readable JSON response.

`lean-beam sync`, `lean-beam save`, and `lean-beam close-save` should be read as a progression rather than as
unrelated commands: `lean-beam sync` establishes the synced diagnostics-complete saved file snapshot,
`lean-beam save` checkpoints that snapshot for one module, and `lean-beam close-save` does the same
checkpoint and then closes the tracked file. This remains a narrower contract than a full batch
rebuild: the save path reports the saved `version`, `sourceHash`, and the `sync` verdict for the
same version. For an unchanged file, `lake build Foo.lean` should replay that saved module, and Lake
should be able to reuse it when rebuilding importers. If the file changes during the save, the
resulting checkpoint remains coherent for the older snapshot and later `lake build` should rebuild
it as stale.

If a speculative probe looks right and should become real source, the current contract is still:
make the real edit in the file, save it, then `lean-beam sync`. The intended future direction is to make
that handoff cheap by reusing speculative execution rather than replaying it from scratch.

`lean-beam save` is module-oriented, not file-oriented. `lean-beam sync` can operate on an arbitrary file the
daemon can open, but `lean-beam save` requires a file that Lake resolves to a module in the current
workspace package graph. Save target resolution loads the real Lake workspace configuration and
does not infer package or module declarations by parsing `lakefile.lean` text in the broker.
Standalone `.lean` files outside that graph are not valid save targets.
The zero-build save path is also restricted to Lake module setups that can be replayed from the LSP
snapshot without custom batch setup. Modules whose Lake setup uses custom Lean options, Lean
arguments, dynamic libraries, or plugins fail with `saveUnsupportedSetup`; use `lake build` for
those modules.

### Sync Reporting Contract

The field-level contract lives in [Sync And Diagnostics Contract](SYNC_AND_DIAGNOSTICS.md). In
short, progress, streamed diagnostics, and current readiness are separate typed concepts.
During alpha, `syncSummary` is the canonical current sync/readiness shape; the contract doc defines
which fields are decisions and evidence.

## Known Limitations

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading is toolchain-keyed, not toolchain-agnostic.
- Supported Lean toolchains are listed in `supported-lean-toolchains`.
- The supported fast path is the Lean toolchain pinned by this repository's `lean-toolchain`,
  because the plugin uses internal Lean APIs.
- The install script prebuilds an installed-skill bundle cache for that pinned toolchain by
  default.
- The install script also accepts `--toolchain <toolchain>` for explicit supported bundles and
  `--all-supported` for the full validated allowlist.
- The install script accepts `--custom-toolchain <toolchain>` for explicit elan-linked local Lean
  development toolchains. These names are recorded in the installed runtime's
  `custom-lean-toolchains` registry and are accepted but not validated.
- Installer locations, MCP registration paths, supported/custom toolchain prebuilds, and
  slow/offline setup are documented in [INSTALL.md](INSTALL.md).
- Runtime requests first try that installed-skill bundle cache, then fall back to a project-local
  runtime bundle under `.beam/bundles/` for supported or explicitly custom toolchains.
- Unsupported Lean toolchains that are not explicitly custom fail early instead of attempting an
  opportunistic build.
- `lean-beam supported-toolchains` lists the validated toolchains, and `lean-beam doctor`
  reports validated support state, custom acceptance state, bundle source, and bundle key inputs.
- Bundle rebuild keys intentionally exclude the full `.lake/packages` checkout tree and instead use
  the resolved toolchain fingerprint, the runtime source tree, `lean-toolchain`,
  `lake-manifest.json`, and `supported-lean-toolchains` / `custom-lean-toolchains`. The fingerprint
  records `lean --version`, `lean --print-prefix`, `lean --print-libdir`, and `lake --version` for
  the requested elan toolchain. See [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the custom
  toolchain and runtime-bundle model.
- The first use of a supported or explicitly custom but not-yet-prebuilt toolchain must still build
  a matching local fallback bundle.
- On a cold machine, that local fallback build may need network access to fetch dependencies.
- In sandboxed agent environments, Beam daemon startup itself may require elevated permissions even when
  the installed bundle and project-local `.beam` paths resolve correctly.
- A startup failure that reports `operation not permitted` through `.beam/beam-daemon-startup.log` is
  usually an environment restriction, not a bundle-resolution mismatch.
- Cancellation is cooperative; prompt stopping depends on inner elaboration polling interruption.
- The Beam daemon is single-root and keeps a conservative single active session per backend.
- `lean-beam-mcp` is currently an experimental stdio entry point. The installed wrapper is the
  preferred local setup path because it passes the matching `beam-cli` resolver automatically.
  `--root PATH` is supported as an explicit override. When it is omitted, clients should either call
  `lean_init_workspace` with one absolute Lean/Lake project root before other Lean tools, or
  advertise exactly one `file://` project root through MCP `roots/list`. Multiple roots are rejected
  for now.
  Direct developer runs of `.lake/build/bin/lean-beam-mcp` can still pass `--lean-cmd` and
  `--lean-plugin` explicitly.
- `lean-beam-mcp` currently advertises MCP protocol revision `2025-11-25` only. Older revisions are
  not advertised or tested.
- `lean-beam-mcp` follows the `2025-11-25` tool-call error split: malformed or unknown tools are
  JSON-RPC protocol errors, while invalid inputs for known tools return MCP tool execution errors
  with `isError=true`.
- `lean-beam-mcp` emits live MCP progress notifications for tool calls that include
  `_meta.progressToken`, forwards incremental Lean diagnostics as MCP log notifications, and still
  leaves MCP cancellation notifications as future work.
- `lean-beam-mcp` has local stdio protocol, Lean-backed restart/stress coverage, deterministic
  Streamable HTTP bridge smoke coverage, and official MCP conformance coverage in CI for the
  selected `server-initialize`, `ping`, and `tools-list` scenarios. The Streamable HTTP bridge is
  test-only; the product entry point remains stdio.
- Zero-build `lean-beam save` helps checkpoint one module, but it is not a whole-workspace freshness
  solution.
- If you edit a dependency of the target file, downstream speculative results should be treated as
  stale until rebuild or checkpoint.
- For open files in Lake workspaces, Beam uses Lean's native stale-dependency diagnostic when a synced
  source change makes an importer need refresh. Beam does not yet implement Lean's dynamic watched-file
  registration, so external source changes that never pass through `sync` remain outside the current
  watcher surface.
- `error.data.staleDirectDeps` recovery hints are still broker-derived metadata. The planned
  direction is to patch Lean's stale-dependency signal to expose the stale dependency information
  Beam needs, then derive these hints from Lean instead of duplicating that state in the broker.
- agent-skill distribution currently relies on a local checkout and local install script; it is not
  yet published through a registry or marketplace flow.
- Optional Rocq support is currently limited to goal inspection through `coq-lsp`; it is not yet a
  full stateful execution layer.

## Direction

Near-term work is mostly about hardening and simplifying:

- keep the base `runAt` request small
- preserve strict per-request isolation
- reduce packaging and workspace rough edges
- publish a smoother distribution path, likely GitHub-backed install for Codex and plugin marketplace packaging for Claude
- improve stale-dependency handling, especially by moving stale dependency metadata into Lean's
  native stale-dependency signal instead of broker-side reconstruction
- upstream structured JSON-RPC error data for Lean request failures, so plugin-level
  `contentModified` errors can carry machine-readable recovery fields such as
  `documentVersionMismatch` without requiring broker-side preflight rejection
- add richer MCP progress percentages or bounded work-unit totals if Lean exposes them; keep
  structured MCP log messages for incremental diagnostics rather than overloading progress
  notifications or the final tool result
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
