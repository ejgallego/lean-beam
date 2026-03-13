# Lean MCTS Search

Use this reference when the task is no longer “try one tactic at one position” and has become
“preserve a speculative proof state, branch from it, run linear playouts, and release side
branches.”

## Core pattern

Use these commands:

```bash
runat lean-run-at-handle "Proofs.lean" 42 6 "constructor"
printf '%s\n' "$HANDLE_JSON" | runat lean-run-with "Proofs.lean" - "constructor"
printf '%s\n' "$HANDLE_JSON" | runat lean-run-with-linear "Proofs.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | runat lean-release "Proofs.lean" -
```

Or use the shorter helper:

```bash
runat-lean-search mint "Proofs.lean" 42 6 "constructor"
printf '%s\n' "$HANDLE_JSON" | runat-lean-search branch "Proofs.lean" "constructor"
printf '%s\n' "$HANDLE_JSON" | runat-lean-search linear "Proofs.lean" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | runat-lean-search playout "Proofs.lean" "exact trivial" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | runat-lean-search release "Proofs.lean"
```

Rules:

- `lean-run-at-handle` mints a preserved root handle from the current saved file
- `lean-run-with` is non-linear: it preserves the current handle and returns a successor handle
- `lean-run-with-linear` is linear: it consumes the current handle and returns a successor handle
- `lean-release` explicitly drops a preserved handle you no longer need
- after a same-document edit, `lean-sync`, close, or restart, reacquire handles from a fresh root

## Minimal branching example

```bash
runat ensure lean
root="$(runat lean-run-at-handle "Proofs.lean" 42 6 "constructor")"

left="$(printf '%s\n' "$root" | runat lean-run-with "Proofs.lean" - "constructor")"
right="$(printf '%s\n' "$root" | runat lean-run-with "Proofs.lean" - "aesop")"

printf '%s\n' "$left" | runat lean-release "Proofs.lean" -
printf '%s\n' "$right" | runat lean-release "Proofs.lean" -
```

Use this when you want to explore multiple children from the same preserved basis.

## Minimal linear playout example

```bash
runat ensure lean
root="$(runat lean-run-at-handle "Proofs.lean" 42 6 "constructor")"
step1="$(printf '%s\n' "$root" | runat lean-run-with-linear "Proofs.lean" - "constructor")"
step2="$(printf '%s\n' "$step1" | runat lean-run-with-linear "Proofs.lean" - "exact trivial")"
printf '%s\n' "$step2" | runat lean-run-with-linear "Proofs.lean" - "exact trivial"
```

Use this when you want one evolving playout path instead of a preserved branch point.

## Root / branch / playout recipe

1. Mint one preserved root handle from the saved file.
2. Use `lean-run-with` from the root to create children.
3. Use `lean-run-with-linear` on a child when you want a playout path that consumes itself step by
   step.
4. Keep preserved handles only when you expect to revisit them.
5. Release side branches aggressively.

Concrete shell sketch:

```bash
runat ensure lean
root="$(runat lean-run-at-handle "Proofs.lean" 42 6 "constructor")"

child_a="$(printf '%s\n' "$root" | runat lean-run-with "Proofs.lean" - "constructor")"
child_b="$(printf '%s\n' "$root" | runat lean-run-with "Proofs.lean" - "aesop")"

playout_a1="$(printf '%s\n' "$child_a" | runat lean-run-with-linear "Proofs.lean" - "exact trivial")"
playout_a2="$(printf '%s\n' "$playout_a1" | runat lean-run-with-linear "Proofs.lean" - "exact trivial")"

printf '%s\n' "$child_b" | runat lean-release "Proofs.lean" -
```

The same sketch with the helper:

```bash
runat ensure lean
root="$(runat-lean-search mint "Proofs.lean" 42 6 "constructor")"
child_a="$(printf '%s\n' "$root" | runat-lean-search branch "Proofs.lean" "constructor")"
child_b="$(printf '%s\n' "$root" | runat-lean-search branch "Proofs.lean" "aesop")"
playout_a="$(printf '%s\n' "$child_a" | runat-lean-search playout "Proofs.lean" "exact trivial" "exact trivial")"
printf '%s\n' "$child_b" | runat-lean-search release "Proofs.lean"
```

## Failure semantics to expect

- semantic tactic failure should not invent a successor handle
- reusing a consumed linear handle should fail
- reusing a released handle should fail
- editing the file invalidates outstanding handles for that document

This means:

- branch handles are reusable until released or invalidated
- linear handles are not reusable after a successful linear step
- failure is data: use it to score the move, then continue from a still-valid preserved handle

## After a real edit

Do not try to salvage old handles.

```bash
# make a real edit and save the source file to disk
runat lean-sync "Proofs.lean"
root="$(runat lean-run-at-handle "Proofs.lean" 42 6 "constructor")"
```

## When to stop using search

Stop branching when one path is clearly good enough to commit to source.

Then:

```bash
# make the real edit in Proofs.lean and save the source file to disk
runat lean-sync "Proofs.lean"
# only after a successful sync on a valid workspace module
runat lean-save "Proofs.lean"
```

## In-repo references

If you are working inside the `runAt` repo itself, the concrete search patterns live in:

- `RunAtTest/Scenario/MctsProofSearchTest.lean`
- `RunAtTest/Scenario/SearchWorkloadReport.lean`
- `tests/scenario/handleSearchCancelDsl.scn`
