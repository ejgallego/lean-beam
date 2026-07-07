# ULC-0002 Backend Readiness Primitive

Status: candidate-0.2.0
Kind: upstream-api
Priority: high
Origin: upstream Lean backlog
Last reviewed: 2026-07-07
Issue: none linked
Lean PR: none linked

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

## Beam Decision

Track as a 0.2.0 upstream Lean roadmap card because it supports the release
theme of actionable failures and reliable recovery. Beam should keep its
current contract stable while looking for a smaller authoritative Lean-side
readiness result.

## Reproduction Status

No upstream Lean PR is linked yet. Local tests exercise Beam's current
readiness boundaries, including sync summaries, save refusal, and incomplete
barriers. They do not remove Beam's broker-side barrier interpretation.

## Preliminary Analysis

This is broader than BUC-0001 and should not block local 0.2.0 fixes. The
lowest-risk path is to keep Beam's current readiness contract stable while
identifying one narrower Lean primitive that can replace broker inference for
sync/save completion. If that primitive is too broad, split this card into a
specific upstream API request and defer the general readiness model.

## Expected Behavior

Lean should expose a typed readiness primitive for a document version that
returns:

- whether diagnostics are complete for that version;
- whether save/checkpoint may proceed;
- blocking diagnostics or failure reasons;
- current diagnostic counts by severity;
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
