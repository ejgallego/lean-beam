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
watchdog path.

## Impact

- Beam can miss the exact stale dependency when Lean reports an out-of-date
  import but the broker-derived direct dependency data is incomplete.
- Broker-side reconstruction duplicates state Lean already knows.
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

This is the upstream counterpart to BUC-0001. The likely Lean-side API should
live near the file-worker/watchdog stale-import path and expose typed module,
URI/path, importer, and rebuild/save necessity. Beam should consume that data
instead of parsing diagnostic text or reconstructing stale direct dependencies
from broker history.

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
