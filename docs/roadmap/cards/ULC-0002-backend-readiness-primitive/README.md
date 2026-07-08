# ULC-0002 Backend Readiness Primitive

Status: open
Kind: upstream-api
Priority: high
Origin: upstream Lean backlog
Last reviewed: 2026-07-08
Issue: none linked
Lean PR: none linked
Upstream timing: as soon as possible

## Summary

Beam's sync and save barriers currently combine diagnostics, file progress, and
backend save-readiness facts to decide whether a document version reached a
complete, save-ready state. The broker should not be the authority for semantic
readiness.

## Impact

- Barrier interpretation is more complex than it should be.
- `fileProgress` is useful evidence, but it is not a general readiness signal.
- A stronger backend-facing primitive would reduce broker inference and make
  save refusal easier to classify.

## Upstream Decision

Track as an active Lean-cycle umbrella card, not as a Beam release blocker.
Beam should keep its current sync/save contract stable while identifying one
or two small Lean-side primitives that can replace broker inference. The pure
frontend readiness helper from
[ULC-0005](../ULC-0005-pure-frontend-readiness-report/README.md) is folded into
this card. Structured stale-dependency document state from
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md) should
be treated as one expected input to readiness, not folded into this umbrella.

## Reproduction Status

No upstream Lean PR is linked yet. Local tests exercise Beam's current
readiness boundaries, including sync summaries, save refusal, and incomplete
barriers. They do not remove Beam's broker-side barrier interpretation.

## Preliminary Analysis

This is broader than BUC-0001 and should not block local Beam fixes. The
lowest-risk path is to keep Beam's current readiness contract stable while
identifying narrower Lean primitives that can replace broker inference for
sync/save completion. Stale dependency state is a concrete blocking reason that
readiness should be able to report once ULC-0001 provides it, but ULC-0001 owns
the stale-dependency data model. Keep this as the umbrella for readiness work;
split only when there is a concrete Lean PR shape.

## Expected Behavior

Lean should expose a typed readiness primitive for a document version that
returns:

- whether diagnostics are complete for that version;
- whether save/checkpoint may proceed;
- blocking diagnostics or failure reasons;
- structured stale-dependency state when it blocks the document;
- current diagnostic counts by severity;
- a pure frontend helper for the build-blocking decision without printing
  diagnostics;
- enough progress identity to explain incomplete states.

Beam would use this as the authority for `lean_sync`, `lean_save`, and
`lean_close_save` final results.

## Evidence

Current boundaries are documented in
[Development](../../../DEVELOPMENT.md#broker-server-boundaries) and
[Sync And Diagnostics](../../../SYNC_AND_DIAGNOSTICS.md).

## Current Workaround

Keep readiness helpers centralized in `Beam/Broker/Readiness.lean`, preserve
the Lean-side save-readiness verdict, and avoid treating `fileProgress` as the
save authority.
