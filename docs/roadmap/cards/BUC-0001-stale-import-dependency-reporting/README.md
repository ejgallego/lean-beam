# BUC-0001 Stale Import Dependency Reporting

Status: candidate-0.2.0
Kind: diagnostics
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-08
Issue: none linked

## Summary

When an edited dependency makes an already-open importer stale, Beam now
returns `syncBarrierIncomplete` with `staleDirectDeps`, `saveDeps`, and a
`recoveryPlan` for observed direct dependencies. The remaining gap is narrower:
when Lean reports an out-of-date import but Beam's broker-derived dependency
hints are empty, the payload should say that the stale import was detected and
that dependency hints are unavailable.

## Impact

- The common direct-dependency cases already return useful save/refresh hints.
- Empty hint arrays are still ambiguous: they may mean "no known stale direct
  dependency" or "Beam could not derive the dependency from current metadata."
- MCP callers need a structured warning for the second case so they can stop
  relying on prose or edit-history inference.

## Beam Decision

Keep a narrowed version in 0.2.0 scope. Direct-dependency recovery is already
implemented and tested; the remaining release-quality issue is the empty-hint
fallback for stale-import diagnostics that Beam can detect but cannot map to a
specific dependency.

This card pairs with
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md). Beam
can improve broker-derived hints, but the cleaner long-term answer is
structured stale-dependency metadata from Lean.

## Reproduction Status

Partially reproduced locally on 2026-07-08. The Beam save-smoke fixtures cover
stale imported targets and currently assert `syncBarrierIncomplete`,
`completionBlockingDiagnostics`, `staleDirectDeps`, `saveDeps`, and
`recoveryPlan` for observed direct dependencies. The focused wrapper
diagnostics suite passed locally:

```text
bash tests/test-beam-wrapper-diagnostics.sh
```

The original LIRIS symptom is narrower than current fixture coverage: an
out-of-date import diagnostic with empty `saveDeps` and `staleDirectDeps`. That
exact project trace still needs a LIRIS retest, but the remaining Beam-side
work can be scoped without it: make the empty-hint fallback explicit whenever a
completion-blocking stale-import diagnostic is present.

## Preliminary Analysis

Beam currently derives stale direct dependencies by intersecting direct imports
returned by the diagnostics barrier with broker module history. That is enough
for the tested direct-dependency cases:

- unsaved dependency changes return `needsSave=true`, `saveDeps`, and a
  save/refresh/build recovery plan;
- saved dependency changes return `needsSave=false`, no save recommendation,
  and a refresh/build recovery plan;
- Lean's stale-import diagnostic is preserved in
  `completionBlockingDiagnostics`.

Empty hints are still expected if either side of the broker-derived join is
missing:

- the diagnostics barrier did not return the relevant direct import;
- the dependency was changed outside Beam's observed sync/save history;
- the stale dependency is not a direct import of the target;
- the Lean diagnostic reports an out-of-date import but does not expose the
  module/path as typed data.

Short-term Beam fix direction: when a stale-import diagnostic is
completion-blocking and hints are empty, return an explicit structured warning
such as `dependencyHintsUnavailable`, include the diagnostic that triggered it,
and keep conservative recovery actions. Long-term fix direction: use
structured Lean stale-dependency metadata, tracked by
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md).

## Expected Behavior

For `syncBarrierIncomplete`, Beam should return actionable dependency entries
when it can derive them:

```json
{
  "saveDeps": [
    {"module": "Liris.Iris.HeapLang.ProofMode", "path": "Liris/Iris/HeapLang/ProofMode.lean"}
  ],
  "staleDirectDeps": [
    {
      "module": "Liris.Iris.HeapLang.ProofMode",
      "path": "Liris/Iris/HeapLang/ProofMode.lean",
      "needsSave": true
    }
  ]
}
```

When Beam detects a stale-import diagnostic but cannot derive a dependency, the
payload should make that limitation explicit:

```json
{
  "dependencyHintsUnavailable": true,
  "staleImportDetected": true,
  "completionBlockingDiagnostics": [
    {
      "completionBlocking": true,
      "message": "Imports are out of date and should be rebuilt; use the \"Restart File\" command in your editor."
    }
  ],
  "recoveryPlan": [
    "lean-beam refresh \"Liris/Tests/OneShot.lean\"",
    "lake build"
  ]
}
```

The recovery plan should eventually include structured MCP-native actions where
possible, not only CLI strings.

## Evidence

Imported from the LIRIS card set. Raw request/response traces were not copied
into this public repository.

Current Beam docs describe the temporary broker-derived recovery fields in
[Sync And Diagnostics](../../../SYNC_AND_DIAGNOSTICS.md#failures-and-recovery).
Local coverage includes `tests/test-beam-wrapper-diagnostics.sh` and
`tests/lean/BeamTest/Broker/ProtocolTest.lean`.

## Current Workaround

After editing an imported file, explicitly sync and save the dependency, then
refresh the importer with `lean_refresh` or with `lean_close` followed by
`lean_sync`.
