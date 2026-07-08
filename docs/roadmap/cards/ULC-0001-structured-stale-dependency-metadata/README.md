# ULC-0001 Structured Stale Dependency Metadata

Status: open
Kind: upstream-api
Priority: high
Origin: upstream Lean backlog
Last reviewed: 2026-07-08
Issue: none linked
Lean PR: none linked
Upstream timing: as soon as possible

## Summary

Beam currently reconstructs stale dependency hints from direct imports returned
by its diagnostics barrier request plus broker sync/save history. That helps,
but the authoritative stale-import signal lives in Lean's file-worker and
watchdog path, where it should be preserved as document state rather than only
rendered as a diagnostic.

## Impact

- Beam can miss the exact stale dependency when Lean reports an out-of-date
  import but the broker-derived direct dependency data is incomplete.
- Broker-side reconstruction duplicates document state Lean already knows.
- Agents get weaker recovery payloads for `syncBarrierIncomplete` failures.

## Upstream Decision

Track as an active Lean-cycle upstream card because it directly supports
[BUC-0001](../BUC-0001-stale-import-dependency-reporting/README.md) and would
let Beam delete broker-derived stale dependency inference. This is not a Beam
release gate: Beam should keep improving local fallback behavior, then prefer
the Lean-provided metadata when it exists.

## Reproduction Status

No upstream Lean PR is linked yet. Local Beam tests prove Beam can consume and
project broker-derived stale dependency hints for observed direct dependencies,
but they do not prove Lean exposes the authoritative stale module/path data
needed for all project shapes.

## Preliminary Analysis

This is the upstream counterpart to BUC-0001. Lean already carries a typed
`staleDependency` URI from the watchdog to the file worker, but the file worker
currently projects it immediately into a sticky diagnostic. The better upstream
shape is to keep this fact in the editable document state, near the existing
sticky diagnostic state, and let diagnostics, code actions, Beam, or other LSP
requests decide how to project it.

The Lean-side data should expose the stale dependency URI and importer URI at
minimum. Module names and rebuild/restart policy can be derived or projected by
clients when available; Beam should not require Lean to encode Beam-specific
save/checkpoint policy such as `needsSave`.

## Expected Behavior

Lean should store structured stale-dependency metadata on the document, with at
least:

- the importer URI;
- the stale dependency URI;
- a stable reason such as `staleDependency`;
- enough lifecycle behavior to clear/update the fact when the worker restarts,
  the dependency is no longer stale, or the document closes.

Diagnostics may still display the current "Restart File" warning, but they
should be a projection of this document state rather than the only carrier of
the stale-dependency fact.

Beam would map that data into `error.data.staleDirectDeps`, `saveDeps`, and
structured recovery steps.

## Evidence

Current temporary behavior is documented in
[Sync And Diagnostics](../../../SYNC_AND_DIAGNOSTICS.md#failures-and-recovery)
and [Status](../../../STATUS.md#sync-save-and-staleness).

Relevant Lean v4.31.0 implementation points:

- `LeanStaleDependencyParams` already carries `staleDependency : DocumentUri`;
- `FileWorker.handleStaleDependency` currently ignores the parameter and
  appends only a sticky diagnostic;
- `EditableDocumentCore` already owns shared sticky diagnostic state across
  document versions, which is the likely area to extend with structured stale
  dependency state.

## Current Workaround

Keep the broker-derived direct-import hint path narrow, tested, and visibly
temporary. Fall back to `lake build` when Beam cannot identify the stale
dependency safely.
