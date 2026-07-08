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

## Reproduction Status

Not reproduced as a failure in this review. The local stale dependency tests
show that the low-level recovery pieces can produce structured hints in the
save-smoke fixture. The remaining issue is command ergonomics, not a missing
primitive.

## Preliminary Analysis

This card should stay downstream of
[BUC-0001](../BUC-0001-stale-import-dependency-reporting/README.md). A
plan/apply API is only safe if the dependency hints are trustworthy and the
write/close effects are explicit. The upstream document-state work in
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md) would
make the dependency input to a future plan/apply API much less speculative,
because Beam would not have to infer the stale dependency only from diagnostics
and broker history. Until then, batching risks turning a recoverable
stale-state problem into a higher-impact workflow operation.

## Expected Behavior

A future surface could expose a planning method and an execution method. The
plan must default to dry-run, avoid silently saving user files, show writes and
closures, stream progress, and fall back to `lake build` when Beam cannot safely
identify the dependency cone.

If Lean exposes structured stale-dependency document state, the plan should use
that state as the authority for importer/dependency relationships, then layer
Beam-local save/checkpoint policy such as `needsSave` on top.

## Evidence

Imported from the LIRIS card set. Raw save/close/sync traces were not copied
into this public repository.

## Current Workaround

Use the existing low-level sequence explicitly: sync/save changed dependencies,
refresh importers, then sync/save targets. Treat save refusal as a domain
failure even when the transport currently reports an invalid-params-style code.
