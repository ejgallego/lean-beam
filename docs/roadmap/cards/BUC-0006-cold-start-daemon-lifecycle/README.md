# BUC-0006 Cold Start And Daemon Lifecycle

Status: candidate-0.2.0
Kind: performance
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07
Issue: https://github.com/ejgallego/lean-beam/issues/110

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

## Reproduction Status

Not reproduced as a daemon failure during this review. The local wrapper
diagnostics suite passed on 2026-07-07 and specifically guards that stale sync
and save failures do not collapse into `Beam daemon connection closed`:

```text
bash tests/test-beam-wrapper-diagnostics.sh
```

The remaining open evidence is intermittent and tracked by
[lean-beam#110](https://github.com/ejgallego/lean-beam/issues/110). That issue
is still the right place to collect CI occurrences and process snapshots.

## Preliminary Analysis

The 0.2.0 slice should focus on failure context, not daemon policy. The useful
implementation target is a daemon incident/tombstone shape that survives client
timeouts and connection closure: root, pid, endpoint, toolchain, Beam source
commit, active request id, active operation, last progress event, and exit
reason when known.

Related but separable work: structured file-worker progress is tracked in
[ULC-0003](../ULC-0003-structured-file-worker-progress/README.md). Beam should
not wait for that upstream improvement before making daemon-side incidents more
actionable.

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

Related Beam issue: [lean-beam#110](https://github.com/ejgallego/lean-beam/issues/110)
tracks intermittent MCP bridge-ready CI timeouts and the diagnostic context
needed for those occurrences.

## Current Workaround

Warm large files with `lean_sync` before speculative probes, keep same-root
save/sync operations mostly serial, and fall back to targeted `lake build` when
the daemon lifecycle becomes part of the problem.
