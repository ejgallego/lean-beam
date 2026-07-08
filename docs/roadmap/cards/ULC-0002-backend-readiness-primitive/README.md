# ULC-0002 Backend Readiness Primitive

Status: open
Kind: upstream-api
Priority: medium
Origin: upstream Lean backlog
Last reviewed: 2026-07-08
Issue: none linked
Lean PR: none linked
Upstream timing: once API shape is clear

## Summary

Beam has a private Lean plugin helper for the document save/checkpoint
readiness verdict. It combines current diagnostics, snapshot-tree message
state, final command-state availability, and save-blocking evidence. This is
useful and correct enough for Beam, but it duplicates Lean-internal knowledge
that would be better owned by Lean if other clients need the same verdict.

## Impact

- Beam must maintain private code over Lean internals such as snapshot trees,
  message logs, final command state, and diagnostic collection.
- Other Lean LSP clients cannot ask the same "can this document be
  checkpointed?" question without copying similar logic.
- `fileProgress` is useful evidence, but it is not a readiness authority; a
  Lean-owned helper would keep that boundary explicit.

## Upstream Decision

Track as Lean-cycle cleanup and deduplication, not as a Beam correctness
blocker. If [ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md)
provides structured stale-dependency document state, Beam can compute its
current readiness payload locally without another Lean patch. The remaining
upstream value is to move Beam's private readiness/checkpoint helper into Lean
when the API shape is useful beyond Beam.

The pure frontend readiness helper from
[ULC-0005](../ULC-0005-pure-frontend-readiness-report/README.md) is folded into
this card. Structured stale-dependency document state from
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md) should
be treated as one expected input to readiness, not folded into this umbrella.

## Reproduction Status

No upstream Lean PR is linked yet. Local tests exercise Beam's current
readiness boundaries, including sync summaries, save refusal, and incomplete
barriers. Those tests show Beam has a working private prototype; they do not
prove that Lean should expose the same helper as public or semi-public API.

## Preliminary Analysis

This is broader than BUC-0001 and should not block local Beam fixes. Beam's
private `SaveReadinessResult` / `collectSaveReadiness` path is the prototype:
it asks whether the current document snapshot can be checkpointed, and returns
typed blocking evidence when it cannot. Once ULC-0001 provides stale dependency
state, Beam can include that as another blocking reason locally.

The upstream opportunity is to factor a Lean-owned document checkpoint
readiness helper from this prototype so Beam and regular Lean LSP code do not
duplicate the same policy. Keep this as an umbrella cleanup card; split only
when there is a concrete Lean PR shape.

## Expected Behavior

Lean could expose a typed document checkpoint-readiness helper for a document
version that returns:

- whether save/checkpoint may proceed;
- blocking diagnostics or failure reasons;
- structured stale-dependency state when it blocks the document;
- current diagnostic counts by severity;
- a pure frontend helper for the build-blocking decision without printing
  diagnostics;
- enough version/hash identity to prevent stale results from being reused.

Beam would use this to shrink or delete its private readiness helper, not to
fix a currently incorrect result.

## Evidence

Current boundaries are documented in
[Development](../../../DEVELOPMENT.md#broker-server-boundaries) and
[Sync And Diagnostics](../../../SYNC_AND_DIAGNOSTICS.md).

## Current Workaround

Keep Beam's private readiness helpers narrow and tested, preserve the
Lean-side save-readiness verdict, and avoid treating `fileProgress` as the save
authority. Prefer upstreaming only when the helper is small enough to be useful
outside Beam.
