# ULC-0001 Structured Stale Dependency Metadata

Status: candidate-0.2.0
Kind: upstream-api
Priority: high
Origin: upstream Lean backlog
Last reviewed: 2026-07-07
Issue: none linked
Lean PR: none linked

## Summary

Beam currently reconstructs stale dependency hints from direct imports returned
by its diagnostics barrier request plus broker sync/save history. That helps,
but the authoritative stale-import signal lives in Lean's file-worker and
watchdog path.

## Impact

- Beam can miss the exact stale dependency when Lean reports an out-of-date
  import but the broker-derived direct dependency data is incomplete.
- Broker-side reconstruction duplicates state Lean already knows.
- Agents get weaker recovery payloads for `syncBarrierIncomplete` failures.

## Beam Decision

Track as a 0.2.0 upstream Lean roadmap card because it directly supports
[BUC-0001](../BUC-0001-stale-import-dependency-reporting/README.md). Beam can
improve local hints, but should prefer deleting broker inference when Lean can
return typed stale-dependency metadata.

## Expected Behavior

Lean should expose structured stale-dependency metadata with at least module
name, path or URI, importer, whether the dependency needs save/rebuild, and the
diagnostic that triggered the stale decision.

Beam would map that data into `error.data.staleDirectDeps`, `saveDeps`, and
structured recovery steps.

## Evidence

Current temporary behavior is documented in
[Sync And Diagnostics](../../../SYNC_AND_DIAGNOSTICS.md#failures-and-recovery)
and [Status](../../../STATUS.md#sync-save-and-staleness).

## Current Workaround

Keep the broker-derived direct-import hint path narrow, tested, and visibly
temporary. Fall back to `lake build` when Beam cannot identify the stale
dependency safely.
