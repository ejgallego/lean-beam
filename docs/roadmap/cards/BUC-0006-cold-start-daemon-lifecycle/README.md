# BUC-0006 Cold Start And Daemon Lifecycle

Status: candidate-0.2.0
Kind: performance
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07

## Summary

Large cold importers and parallel sync/save activity have produced opaque
timeouts, daemon connection closures, and low-level hangs. Some reports are old
wrapper-era evidence, but the current need remains: Beam should expose progress
and preserve enough post-failure state for a useful bug report.

## Impact

- Cold setup can outlive client patience without enough phase information.
- `Beam daemon connection closed` is too ambiguous without attached context.
- Post-failure reports need root, pid, port, toolchain, source commit, active
  operation, last progress event, and exit reason.

## Beam Decision

Keep a narrow version in 0.2.0 scope: better failure reporting and tombstone
context. Do not expand this into a broad daemon metrics or orchestration
project for 0.2.0.

## Expected Behavior

Beam should make cold work visible and failures reportable:

- stream progress for Lake setup, import loading, worker startup, and file
  elaboration phases;
- return retryable structured errors before client tool timeouts where
  possible;
- preserve daemon tombstones containing root, pid, port, toolchain, source
  commit, last request id, active operation, last progress event, and exit
  reason;
- avoid ambiguous connection-closed errors without attached context;
- document expected concurrency semantics for same-root sync/save.

## Evidence

Imported from the LIRIS card set. Raw logs, strace output, and gdb artifacts
were not copied into this public repository.

## Current Workaround

Warm large files with `lean_sync` before speculative probes, keep same-root
save/sync operations mostly serial, and fall back to targeted `lake build` when
the daemon lifecycle becomes part of the problem.
