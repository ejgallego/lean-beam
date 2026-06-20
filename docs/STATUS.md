# Status

Lean Beam is alpha code and still mostly a personal experiment.

The repository is public for collaboration and reuse, but it is not yet a polished or stable
general-purpose product. The main goal is still a small, type-safe, isolated execution surface for
Lean, with a thin local Beam daemon around it for low-cost experimentation.

## Current Scope

- standalone Lean plugin for `$/lean/runAt`
- internal proof-first, command-fallback basis selection
- typed response payload with messages, traces, optional proof state, and optional follow-up handle
- optional follow-up execution through `$/lean/runWith` and `$/lean/releaseHandle`
- agent-oriented `$/lean/todo` range inspection for actionable items such as sorries, holes,
  diagnostics, code actions, and incomplete proofs, exposed through the broker, `lean-beam todo`,
  and MCP `lean_todo`
- local Beam daemon/client pair for Lean and Rocq workflows
- alpha Lean wrapper commands for follow-up handle continuation and release
- installed `lean-beam-search` helper for shorter shell branching/playout workflows
- explicit broker `ok` / `error` response envelopes for machine-readable local protocol consumers,
  while still accepting older inferred-`ok` envelopes on input
- installed experimental `lean-beam-mcp` stdio server exposing the curated Lean Beam tool set through
  MCP `initialize`, `tools/list`, and `tools/call`, backed directly by the broker runtime rather
  than a second daemon/client connection
- MCP `lean_init_workspace` setup tool for clients that can register only a generic global server
  command and do not advertise MCP roots. It requires an absolute Lean/Lake project root and keeps
  root switching explicit; see [MCP Workspace Initialization](#mcp-workspace-initialization).
- `lean-beam-mcp --self-check <lean-file>` setup verification for the installed MCP path, explicit
  `lean_init_workspace` runtime setup, and a real `lean_sync` tool call
- explicit Lean `lean-beam sync` Beam-daemon barrier with diagnostics wait and compact `fileProgress` reporting
- `lean-beam open-files` Beam-daemon introspection for tracked documents, including `saved` / `notSaved`,
  direct Lean deps when available, whether the current synced version has been checkpointed with
  `lean-beam save`, and Lean save preflight fields `saveEligible` / `saveReason` / `saveModule`;
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
- one Lean text payload
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

The local Beam daemon convenience layer is also still alpha. In particular, `lean-beam sync` is now the
supported on-disk edit barrier for Lean files: it waits for diagnostics for the synced version and
streams fresh diagnostics to clients such as the CLI without replaying them in the final JSON, and
returns a compact `fileProgress` summary rather than exposing the full underlying LSP notification
stream. By default `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` stream only errors for the
current request; `+full` widens that stream to warnings, info, and hints. The Beam daemon now also
forwards compact `fileProgress` updates live to streaming clients. The final `sync` result counts
the current synced document state under save-readiness semantics: `errorCount` is the current
save-blocking frontend error count, not a count of Lean diagnostics whose severity is `error`.
`warningCount` is the current warning count, and `saveReady` / `stateErrorCount` /
`stateCommandErrorCount` describe whether Beam's save/checkpoint path should proceed. This is
deliberately separate from streamed diagnostics: the stream reports diagnostic events observed
while the current request was pending, whereas the final result reports the current synced state.
Successful sync responses also include `result.syncSummary`, a typed versioned summary with
`currentVersion`, optional `deltaBaseVersion`, current diagnostic/readiness counts, and
diagnostic/readiness deltas against the previous successful sync boundary when one is available.
Consumers that need incremental diagnostics should still use `beam-client request-stream` and treat
`result.syncSummary.readiness.current.saveReady` / `saveBlockingErrorCount` as the authoritative
save-readiness summary. When the current sync verdict is not save-ready,
`result.syncSummary.readiness.current.blockingDiagnostics` and `blockingCommandMessages` contain the
frontend diagnostics and command messages that blocked saving; each entry carries
`saveBlocking=true`. If the save-readiness payload reports blocking counts without explicit
evidence, Beam falls back to the current completed-barrier error diagnostics and marks them
`saveBlocking=true`.
`lean-beam save` and `lean-beam close-save` project the current flat sync verdict into successful
save payloads as `sync` / `saved.sync`, and document-error save failures include it in
`error.data.sync`, so checkpointing decisions can be traced back to the synced version that was just
established, including its `blockingDiagnostics` and `blockingCommandMessages`.
For programmatic local consumers,
the preferred machine-readable surface is the JSON stream exposed
by `beam-client request-stream`; the wrapper stderr format should be treated as human-facing.
Beam broker responses include an explicit top-level `ok` boolean. Older response envelopes that omit
`ok` still decode by inferring success from the absence of `error`, but new producer code should emit
`ok` because it gives future projection layers an unambiguous success/error discriminator.
Other slow Lean Beam daemon calls may attach a compact top-level `fileProgress` summary when they had
to wait on the same Lean elaboration progress. For non-barrier calls this summary may be partial,
because the request can return before the whole file reaches `done = true`. This should be read as a
Lean-side wrapper contract: `fileProgress` is observability except where `sync`, `save`, and
`close-save` explicitly use it as a diagnostics-completion barrier input. MCP setup progress is a
separate concern; the self-check path now reports explicit workspace setup before running
`lean_sync`, so slow bundle/runtime setup is not described as Lean-file sync latency.
The wrapper now also exposes alpha Lean handle commands for
continuation, linear playout, and release; these are useful for search-style workflows but are still
more fragile than the base one-shot request. Rocq support remains narrower and does not currently
expose an equivalent public sync command in the wrapper.

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
workspace package graph. Standalone `.lean` files outside that graph are not valid save targets.

### Progress And Sync Delta Reporting

Progress, diagnostics, readiness, and deltas are separate typed concepts:

| Concept | Scope | Current surface |
| --- | --- | --- |
| Progress | Request-scoped operation movement, not diagnostics and not final readiness. | MCP `notifications/progress`; Beam stream `progress` events; CLI progress text. |
| Streamed diagnostics | Lean-published events observed while a request is pending. | MCP `notifications/message` with logger `lean.diagnostic`; Beam stream `diagnostic` events; CLI stderr diagnostics. |
| Current summary | Stable synced-state verdict for one document version. | Final structured tool result and broker response fields such as `saveReady`, `errorCount`, and `file_progress`. |
| Delta summary | Comparison against one named previous sync boundary. | `result.syncSummary` diagnostic/readiness deltas when a previous sync boundary exists. |

For MCP, Beam forwards incremental Lean diagnostics as structured `notifications/message` log
events with path, URI, version, range, severity, and message data. These diagnostics are deliberately
not encoded as progress. Beam also parses tool-call `_meta.progressToken` and emits
`notifications/progress` for request-scoped setup and execution phases, plus throttled Lean
`fileProgress.line` / `totalLines` / `updates` / `done` details, before the final JSON-RPC response.
The numeric `progress` value is a per-request monotonic sequence. File-progress messages use
`<tool> fileProgress line=<current>/<total> updates=<n> done=<true|false>` when Lean reports a
processing range, omit the line segment when no range is available, and are emitted on the first
observed update, periodically while the update count advances, and when the final `done=true` state
is observed. The final structured tool result also includes these fields in `file_progress` when
Lean file progress was observed.

Successful `lean-beam sync` responses expose the current and delta summaries under
`result.syncSummary`. The existing flat `result.errorCount`, `result.warningCount`,
`result.saveReady`, `result.stateErrorCount`, and `result.stateCommandErrorCount` fields are kept
as compatibility fields and continue to describe the current save-readiness verdict. In new
machine consumers, prefer the typed fields under `result.syncSummary`.

Diagnostic severity and save readiness intentionally answer different questions. Use
`diagnostics.current.error` for the current count of Lean-published error-severity diagnostics. Use
`readiness.current.saveBlockingErrorCount` and `readiness.current.saveReady` for the
save/checkpoint decision. Some Lean extensions can publish interactive error diagnostics from child
snapshots that do not block saving, so a valid sync summary may have
`diagnostics.current.error > 0` and `readiness.current.saveReady = true` at the same
`currentVersion`. When `readiness.current.saveReady = false`,
`readiness.current.blockingDiagnostics` and `readiness.current.blockingCommandMessages` identify the
errors that caused that decision and carry `saveBlocking=true`; if the save-readiness payload has no
explicit evidence, Beam uses the current completed-barrier error diagnostics as fallback evidence.

For MCP, Beam forwards incremental Lean diagnostics as structured `notifications/message` log
events with path, URI, version, range, severity, message data, and `completionBlocking=true` when
the diagnostic is known to block file completion. Streamed diagnostics remain request-scoped
observations; save-readiness evidence is attached to the final sync/save verdict instead of being
retroactively added to earlier stream events. These diagnostic logs are deliberately separate from
MCP `notifications/progress`.

For sync deltas, every delta-bearing payload states both sides of the comparison:

- `currentVersion`: the synced document version described by the current result
- `deltaBaseVersion?`: the previous successful sync version used as the comparison base, absent on
  the first successful sync for a document or after a reset/close boundary that discards history
- `sourceChangedSinceDeltaBase`: whether the source text hash changed between `deltaBaseVersion`
  and `currentVersion`
- `diagnostics.current`: current Lean-published diagnostic counts by severity and total
- `diagnostics.delta`: added / removed / persisted counts keyed by Beam's diagnostic identity
  `(range, effective severity, message)`, with `baseVersion` and `currentVersion` repeated inside
  the delta object
- `readiness.current`: save-blocking errors, command/frontend errors, warnings, `saveReady`,
  `saveReadyReason`, and the blocking diagnostics/messages that carry `saveBlocking=true`
- `readiness.delta`: count changes and readiness-state changes between the same base/current
  versions

`save` and `close-save` already return the current flat sync verdict they established before
checkpointing, including save-blocking diagnostic/message evidence on failures. They do not yet
return the typed versioned sync summary above. A follow-up should project that summary, or an
explicit reference to it, while still requiring
`readiness.current.saveReady = true` for that exact `currentVersion` before saving that version and
reporting the saved source hash.

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
- Lean does not yet expose a better plugin-facing restart-required / stale-dependency hook here, so
  this limitation is currently explicit and user-visible.
- agent-skill distribution currently relies on a local checkout and local install script; it is not
  yet published through a registry or marketplace flow.
- Rocq support is currently limited to goal inspection through `coq-lsp`; it is not yet a full
  stateful execution layer.

## Direction

Near-term work is mostly about hardening and simplifying:

- keep the base `runAt` request small
- preserve strict per-request isolation
- reduce packaging and workspace rough edges
- publish a smoother distribution path, likely GitHub-backed install for Codex and plugin marketplace packaging for Claude
- improve stale-dependency handling
- replace broker-side diagnostics/fileProgress barrier inference with a stronger backend-facing
  readiness primitive, so `lean-beam sync` / `lean-beam save` can trust one authoritative completion signal
  instead of reconstructing barrier completeness from multiple LSP channels
- track an upstream Lean API improvement for a pure frontend readiness/reporting helper, close to
  `SnapshotTree.runAndReport` but returning the build-blocking decision and message counts without
  printing, so Beam can delegate save-ready semantics instead of mirroring private frontend logic
- add richer MCP progress percentages or bounded work-unit totals if Lean exposes them; keep
  structured MCP log messages for incremental diagnostics rather than overloading progress
  notifications or the final tool result
- project the typed versioned sync summary, or an explicit reference to it, through `save` /
  `close-save` alongside the flat sync verdict that checkpointing already establishes
- keep Beam-daemon-side conveniences useful without turning them into a large public surface too early
- add a short comparison against Pantograph in the docs, to clarify where `runAt` fits among nearby Lean tooling
- keep cross-surface utility code such as root resolution and workspace-relative path derivation in
  shared Beam modules, not copied across CLI, broker, MCP, and test helpers

## Release Focus

The first Lean release should stay conservative:

- keep the public `runAt`, `lean-beam`, and MCP surfaces small and documented
- keep CLI and MCP as thin projections over shared typed operation adapters
- keep compatibility and install behavior covered across every supported Lean toolchain in CI
- take stability fixes when they materially improve release confidence
- defer broader dependency/readiness redesigns until Lean or Lake expose stronger primitives
