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
