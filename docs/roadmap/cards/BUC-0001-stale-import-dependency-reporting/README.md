# BUC-0001 Stale Import Dependency Reporting

Status: candidate-0.2.0
Kind: diagnostics
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07
Issue: none linked

## Summary

When an edited dependency has been synced but not saved, syncing an already
open importer can fail with `syncBarrierIncomplete` and an out-of-date import
diagnostic while `saveDeps` and `staleDirectDeps` are empty. The agent then has
to infer the dependency from edit history rather than from Beam's recovery
payload.

## Impact

- The recovery plan can correctly say the importer must be refreshed or rebuilt.
- The payload sometimes omits the dependency module or path that should be saved
  or refreshed first.
- Human CLI text can mention `lean-beam refresh`, while MCP callers need
  structured next actions rather than prose.

## Beam Decision

Keep this in 0.2.0 scope. This is a release-quality issue because stale import
failures are common in real editing sessions, and Beam should make the next
action obvious.

This card pairs with
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md). Beam
can improve broker-derived hints, but the cleaner long-term answer is
structured stale-dependency metadata from Lean.

## Reproduction Status

Partially reproduced locally on 2026-07-07. The Beam save-smoke fixtures cover
stale imported targets and currently assert `syncBarrierIncomplete`,
`staleDirectDeps`, `saveDeps`, and `recoveryPlan` for direct dependencies. The
focused wrapper diagnostics suite passed locally:

```text
bash tests/test-beam-wrapper-diagnostics.sh
```

The original LIRIS symptom is narrower: an out-of-date import diagnostic with
empty `saveDeps` and `staleDirectDeps`. That exact project trace still needs a
LIRIS retest before deciding whether current Beam has closed the gap or only
the smaller fixture case.

## Preliminary Analysis

Beam currently derives stale direct dependencies by intersecting Lean-reported
direct imports with broker module history. Empty hints are expected if either
side is missing:

- the diagnostics barrier did not return the relevant direct import;
- the dependency was changed outside Beam's observed sync/save history;
- the stale dependency is not a direct import of the target;
- the Lean diagnostic reports an out-of-date import but does not expose the
  module/path as typed data.

Short-term Beam fix direction: when an out-of-date import diagnostic is
completion-blocking and hints are empty, return an explicit structured
`staleImportDetected` / `dependencyHintsUnavailable` note with the diagnostic
and conservative recovery actions. Long-term fix direction: use structured
Lean stale-dependency metadata, tracked by
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md).

## Expected Behavior

For `syncBarrierIncomplete`, Beam should return at least one actionable
dependency entry whenever the blocking diagnostic is an out-of-date import:

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

The recovery plan should include structured MCP-native actions where possible,
not only CLI strings.

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
