# BUC-0001 Stale Import Dependency Reporting

Status: candidate-0.2.0
Kind: diagnostics
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07

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

## Current Workaround

After editing an imported file, explicitly sync and save the dependency, then
refresh the importer with `lean_refresh` or with `lean_close` followed by
`lean_sync`.
