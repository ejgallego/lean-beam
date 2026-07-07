# BUC-0005 Diagnostics, Todo, And Progress Metadata

Status: deferred
Kind: diagnostics
Priority: medium
Origin: LIRIS
Last reviewed: 2026-07-07

## Summary

Beam diagnostics are more useful than before, but agents still need a cleaner
distinction between readiness-blocking errors, proof-state archaeology,
ordinary info diagnostics, and progress metadata. Broad `lean_todo` over
completed proofs can report intermediate proof states and non-blocking
messages even when `lean_sync` and `lean_save` are clean.

## Impact

- Broad `lean_todo` can be noisy when used as a file-readiness test.
- Agents can confuse progress observations with readiness decisions.
- `fileProgress` fields need careful interpretation because Lean progress
  ranges are not the physical file line count.

## Beam Decision

Defer for 0.2.0 unless it produces a small documentation or filtering cleanup.
The current docs already define progress, streamed diagnostics, and readiness
as separate concepts. Remaining `todo` filtering improvements can be handled as
polish after higher-risk recovery cards.

## Expected Behavior

Suggested improvements:

- Separate saved incomplete declarations from intermediate tactic proof states.
- Provide a readiness-oriented todo mode that reports only items blocking saved
  source acceptance.
- Label diagnostics by role, for example `blocking`, `informational`,
  `intermediate-proof-state`, and `lint`.
- Keep file progress fields stable and documented.

## Evidence

Imported from the LIRIS card set. Raw stress reports were not copied into this
public repository.

The current field-level contract lives in
[Sync And Diagnostics](../../../SYNC_AND_DIAGNOSTICS.md).

## Current Workaround

Use `lean_sync` / `lean_save` readiness as the validation gate. Use `lean_todo`
on narrow ranges and explicit kinds when inspecting proof states, not as a
broad file-readiness test.
