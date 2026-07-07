# BUC-0002 Internal Exception For Tactic-Position Term Ascription

Status: close-candidate
Kind: bug
Priority: critical
Origin: LIRIS
Last reviewed: 2026-07-07
Issue: none linked

## Summary

A minimized tactic-position `lean_run_at` / `lean_run_at_handle` request used
to return only `internal exception #5` for a bad `have` with a term ascription:

```lean
have htest := (Nat.succ : Nat)
```

Equivalent top-level examples and nearby tactic controls reported ordinary Lean
type mismatch diagnostics.

## Impact

- The response looked like an internal Beam failure rather than a normal Lean
  type error.
- Agents could misclassify the source proof as blocked.
- The opaque exception number gave no actionable recovery path.

## Beam Decision

Close or archive after one final retest on the current release candidate. Beam
now has regression coverage that expects the ordinary type mismatch diagnostic
and no stored handle for the semantic failure path.

## Expected Behavior

Beam should return a structured ordinary Lean diagnostic for the bad ascription,
or a structured unsupported-path error. It should not return only an opaque
internal exception number.

## Evidence

Imported from the LIRIS card set. Raw minimized request/response traces were
not copied into this public repository.

Relevant local coverage lives in
[tests/lean/BeamTest/LSP/Handle/Api.lean](../../../../tests/lean/BeamTest/LSP/Handle/Api.lean).

## Current Workaround

When an opaque internal exception appears, minimize in a save-ready file and
compare tactic-position controls with a top-level example before classifying
the source proof as blocked.
