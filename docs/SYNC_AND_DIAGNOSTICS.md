# Sync And Diagnostics Contract

This is the canonical contract for Beam sync, save, progress, diagnostics, and readiness reporting
across the wrapper, broker stream, and MCP server.

## Command Model

`lean-beam sync` is the on-disk edit barrier for a Lean file. It opens or updates the tracked file,
waits for diagnostics for the synced version, streams fresh request diagnostics, and returns a
compact JSON verdict for that version.

`lean-beam save` is `sync` plus a zero-build checkpoint for the synced Lake module. `lean-beam
close-save` is `save` plus closing the tracked file afterward. Both commands return the sync verdict
they established before checkpointing: `save` under `result.sync`, and `close-save` under
`result.saved.sync`. Document-error save failures include the blocking verdict under
`error.data.sync`.

Zero-build checkpointing is restricted to Lake module setups Beam can replay from the LSP snapshot
without custom batch setup. Save target resolution delegates to Lake's workspace loader for the
project's real `lakefile.lean` or `lakefile.toml`; the broker does not synthesize fallback Lake
configuration from `lakefile.lean` text. If Lake setup for a module uses custom Lean options, Lean
arguments, dynamic libraries, or plugins, `save` and `close-save` fail with `saveUnsupportedSetup`
after the sync verdict is established. In that case, use `lake build` for the module or importer
instead of expecting Beam to write Lake artifacts.

## Reporting Surfaces

Progress, streamed diagnostics, current summaries, and deltas are separate typed concepts.

| Concept | Scope | Current surface |
| --- | --- | --- |
| Progress | Request-scoped operation movement, not diagnostics and not final readiness. | MCP `notifications/progress`; Beam stream `progress` events; CLI progress text. |
| Streamed diagnostics | Lean-published events observed while a request is pending. | MCP `notifications/message` with logger `lean.diagnostic`; Beam stream `diagnostic` events; CLI stderr diagnostics. |
| Current summary | Stable synced-state verdict for one document version. | Final structured tool result and broker response fields such as `saveReady`, `errorCount`, and `file_progress`. |
| Delta summary | Comparison against one named previous sync boundary. | `syncSummary` diagnostic/readiness deltas when a previous sync boundary exists. |

Wrapper stderr is the human-facing surface. Machine consumers should use final stdout JSON or the
broker JSON stream exposed by `beam-client request-stream`.

## MCP Diagnostics

The MCP server advertises logging and forwards incremental Lean diagnostics as structured
`notifications/message` log events. These events include path, URI, version, range, severity,
message data, and `completionBlocking=true` when a diagnostic is known to block file completion.
They are request-scoped observations; save-blocking evidence is attached to the final sync/save
verdict.

MCP clients that cannot conveniently collect interleaved notifications can call `lean_sync` with
`include_diagnostics: true` to replay diagnostics in the final structured result. By default replay
and streaming use an error-only diagnostic filter. `full_diagnostics: true` widens that output to
warnings, information, and hints.

`full_diagnostics` is an output severity/detail filter, not a request for a partial diagnostic
state. `syncSummary.diagnostics.current` still summarizes the complete current diagnostic state.

## Progress

MCP clients can pass `_meta.progressToken` on `tools/call` requests to receive
`notifications/progress` for setup and execution phases. Beam also reports throttled Lean
file-progress observations when Lean publishes them.

`fileProgress` and MCP `file_progress` fields contain compact Lean processing-range observations:
`line`, `totalLines`, `updates`, and `done`. They are not verified source line counts and should not
be compared to `wc -l`. Use them for coarse UI progress only. Final machine decisions should use
the readiness and diagnostic summary fields.

For `sync`, `save`, and `close-save`, completed Lean file progress is one input to the
diagnostics-complete barrier. For non-barrier calls, file progress may be partial because the
request can return before the whole file reaches `done = true`.

## Readiness

Successful sync responses expose the current verdict and optional delta under `syncSummary`. New
machine consumers should prefer:

- `syncSummary.readiness.current.saveReady`
- `syncSummary.readiness.current.saveBlockingErrorCount`
- `syncSummary.readiness.current.blockingDiagnostics`
- `syncSummary.readiness.current.blockingCommandMessages`

`syncSummary.diagnostics.current.*` reports Lean-published diagnostic severities. It answers "what
did Lean report?", while readiness answers "can this synced version be checkpointed?". The backend
readiness API is authoritative for `saveReady`; diagnostic severity summaries are evidence and
counts, not a separate broker-side veto.

Lean-side readiness follows Lean batch/Lake's artifact gate for the current synced snapshot: errors
in the full snapshot tree's current reportable messages block save, while errors that exist only in
Lean's already-reported message history do not block save by themselves.

The flat fields `errorCount`, `warningCount`, `saveReady`, `stateErrorCount`, and
`stateCommandErrorCount` are top-level projections in the current alpha response shape. They should
agree with the actionable current state, but they are not separate compatibility commitments.
Machine consumers should prefer `syncSummary`.

## Deltas

When a previous successful sync boundary exists, `syncSummary` also reports deltas. Every
delta-bearing payload states both sides of the comparison:

- `currentVersion`: the synced document version described by the current result
- `deltaBaseVersion?`: the previous successful sync version used as the comparison base
- `sourceChangedSinceDeltaBase`: whether the source text hash changed between the versions
- `diagnostics.current`: current Lean-published diagnostic counts by severity and total
- `diagnostics.delta`: added, removed, and persisted counts keyed by Beam's diagnostic identity
- `readiness.current`: the current save-readiness verdict and blocking evidence
- `readiness.delta`: readiness-state changes between the same base and current versions

## Failures And Recovery

If Lean cannot reach a completed diagnostics barrier for the synced version, `lean-beam sync` fails
instead of reporting partial success. `lean-beam save` and `lean-beam close-save` refuse to proceed
past that incomplete barrier.

Sync failures may include `error.data.staleDirectDeps`, `error.data.saveDeps`,
`error.data.recoveryPlan`, and `error.data.completionBlockingDiagnostics`. Recovery hints are based
on direct imports whose saved checkpoint is newer than the target file's last successful sync
boundary. `completionBlockingDiagnostics` entries carry `completionBlocking=true` when they explain
why the file could not reach a diagnostics-complete barrier.

## Upstream Readiness Direction

Beam asks the backend for the save-readiness verdict and keeps progress and diagnostic observations
as separate request facts. The desired end state is a stronger backend-facing readiness primitive:
a typed result that directly reports barrier completion, diagnostic counts, save-blocking evidence,
and file-progress observations without relying on broker-side inference.

One useful upstream Lean direction is a close relative of `SnapshotTree.runAndReport` that returns
the diagnostics/progress decision data instead of only printing or reporting it through side
channels. That would make the public Beam contract simpler and reduce duplicate normalization logic
across CLI, broker, and MCP surfaces.
