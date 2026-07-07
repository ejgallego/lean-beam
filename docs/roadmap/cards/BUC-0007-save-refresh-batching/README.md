# BUC-0007 Save And Refresh Batching

Status: deferred
Kind: feature
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07
Issue: none linked

## Summary

After editing dependencies, agents often need a repetitive sequence:

```text
sync dependency
save dependency
refresh importer
sync importer
save importer
```

Beam exposes enough low-level pieces to recover, but the recovery plan is
spread across diagnostics, CLI text, edit history, and agent memory.

## Impact

- Agents repeat fragile save/refresh chains by hand.
- Recovery commands are easy to run in the wrong order.
- A batched operation could reduce command count and make writes/closures more
  explicit.

## Beam Decision

Defer for 0.2.0. This is attractive, but it adds a new public operation. First
make stale dependency hints reliable enough that any future plan/apply API can
be small and trustworthy.

## Expected Behavior

A future surface could expose a planning method and an execution method. The
plan must default to dry-run, avoid silently saving user files, show writes and
closures, stream progress, and fall back to `lake build` when Beam cannot safely
identify the dependency cone.

## Evidence

Imported from the LIRIS card set. Raw save/close/sync traces were not copied
into this public repository.

## Current Workaround

Use the existing low-level sequence explicitly: sync/save changed dependencies,
refresh importers, then sync/save targets. Treat save refusal as a domain
failure even when the transport currently reports an invalid-params-style code.
