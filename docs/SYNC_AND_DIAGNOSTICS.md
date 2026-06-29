# Sync And Diagnostics Contract

This is the canonical contract for Beam sync, save, progress, diagnostics, and readiness reporting
across the wrapper, broker stream, and MCP server.

## Command Model

`lean-beam update` is the cheap on-disk edit observation for a Lean file. It reads the current file,
opens or updates the broker's LSP mirror when needed, and returns the broker-owned document
`version` immediately without waiting for diagnostics. Its `changed` flag means the broker sent
`didOpen` or `didChange` to the LSP session for this request; unchanged files keep the previous
document version and return `changed: false`.

`lean-beam sync` is the diagnostics/readiness barrier for a Lean file. It opens or updates the
tracked file, waits for diagnostics for the current document version, streams fresh request
diagnostics, and returns a machine-readable JSON verdict for that version. Wrapper stdout uses
stable, agent-oriented field ordering; `beam-client request-stream` is the compact one-line JSON
stream for programmatic event consumers.

The returned document `version` is the snapshot token for broker, MCP, and wrapper callers.
Position- or range-bound operations reject missing or stale versions; clients can obtain the
version from `lean-beam update`, broker `update_file`, or MCP `lean_update`. `lean-beam sync`,
broker `sync_file`, and MCP `lean_sync` also return the current version when the caller needs the
diagnostics/readiness barrier.

When the broker rejects a position- or range-bound request because the supplied version is stale,
the failure uses `contentModified` and includes `error.data.reason = "documentVersionMismatch"`.
The same payload reports `expectedVersion`, the currently accepted `acceptedVersion`, and
`currentVersion` when the broker can name the current tracked document version.

Example stale-version response:

```json
{
  "ok": false,
  "error": {
    "code": "contentModified",
    "message": "document version mismatch for file:///workspace/Foo.lean: expected document version 1, got 2",
    "data": {
      "reason": "documentVersionMismatch",
      "expectedVersion": 1,
      "acceptedVersion": 2,
      "currentVersion": 2,
      "uri": "file:///workspace/Foo.lean"
    }
  }
}
```

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

Progress, streamed diagnostics, and current summaries are separate typed concepts.

| Concept | Scope | Current surface |
| --- | --- | --- |
| Progress | Request-scoped operation movement, not diagnostics and not final readiness. | MCP `notifications/progress`; Beam stream `progress` events; CLI progress text. |
| Streamed diagnostics | Lean-published events observed while a request is pending. | MCP `notifications/message` with logger `lean.diagnostic`; Beam stream `diagnostic` events; CLI stderr diagnostics. |
| Current summary | Stable synced-state verdict for one document version. | Final structured tool result and broker response fields such as `syncSummary` and `file_progress`. |

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

`fileProgress` and MCP `file_progress` fields contain compact Lean processing-range observations.
They always report `updates` and `done`; when Lean publishes range-bearing progress, they may also
report `rangeStartLine` and/or `rangeEndLine`. `rangeEndLine` is the upper line bound reported by
Lean's progress ranges, not the source file's line count; diagnostics may legitimately refer to
lines beyond it. Use these fields for coarse UI progress only. Final machine decisions should use
the readiness and diagnostic summary fields.

For `sync`, `save`, and `close-save`, completed Lean file progress is one input to the
diagnostics-complete barrier. For non-barrier calls, file progress may be partial because the
request can return before the whole file reaches `done = true`.

## Readiness

Successful sync responses expose the current verdict under `syncSummary`. The machine-facing
readiness fields are:

- `syncSummary.readiness.current.saveReady`
- `syncSummary.readiness.current.errorCount`
- `syncSummary.readiness.current.warningCount`
- `syncSummary.readiness.current.blockingDiagnostics`
- `syncSummary.readiness.current.blockingCommandMessages`

`syncSummary.diagnostics.current.*` reports Lean-published diagnostic severities. It answers "what
did Lean report?", while readiness answers "can this synced version be checkpointed?". The backend
readiness API is authoritative for `saveReady`; diagnostic severity summaries are evidence and
counts, not a separate broker-side veto.

Lean-side readiness follows Lean batch/Lake's artifact gate for the current synced snapshot:
current save-blocking frontend errors block save. Diagnostic streams, diagnostic summaries, and
message history are observations; clients should not reconstruct save readiness from them.

## Current Summary

Each `syncSummary` describes only the current synced document version. It does not carry deltas
against previous responses. Clients that need comparisons should retain the previous response they
care about and compare it explicitly.

- `currentVersion`: the synced document version described by the current result
- `diagnostics.current`: current Lean-published diagnostic counts by severity and total
- `readiness.current`: the current save-readiness verdict and blocking evidence

## Failures And Recovery

If Lean cannot reach a completed diagnostics barrier for the synced version, `lean-beam sync` fails
instead of reporting partial success. `lean-beam save` and `lean-beam close-save` refuse to proceed
past that incomplete barrier.

Sync failures may include `error.data.staleDirectDeps`, `error.data.saveDeps`,
`error.data.recoveryPlan`, and `error.data.completionBlockingDiagnostics`. For now, recovery hints
are based on direct imports whose saved checkpoint is newer than the target file's last successful
sync boundary, but the intended direction is to get stale-dependency metadata from Lean's native
stale-dependency signal instead of reconstructing it in Beam. `completionBlockingDiagnostics`
entries carry `completionBlocking=true` when they explain why the file could not reach a
diagnostics-complete barrier.

For Lake workspaces, Beam starts the Lean server with Lake's workspace environment so Lean's own
import graph can detect stale open importers. When `sync` observes a real source change for an open
Lean file, Beam sends `textDocument/didChange` followed by `textDocument/didSave`; Lean may then
publish its native "Imports are out of date" diagnostic on open dependents, and Beam reports that
diagnostic as `syncBarrierIncomplete`. Beam does not currently implement Lean's dynamic
`workspace/didChangeWatchedFiles` watcher registration, so external source changes that never pass
through `sync` are not treated as a complete file-watcher surface.
