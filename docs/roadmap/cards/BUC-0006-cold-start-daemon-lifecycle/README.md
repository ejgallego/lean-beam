# BUC-0006 Cold Start And Daemon Lifecycle

Status: resolved
Kind: performance
Priority: high
Origin: LIRIS
Last reviewed: 2026-08-14
Issue: https://github.com/ejgallego/lean-beam/issues/110

## Summary

Large cold importers and parallel sync/save activity had produced opaque
timeouts, daemon connection closures, and low-level hangs. Beam now enriches
daemon-closure failures with registry and log context and preserves bounded JSON
incident records for post-failure reports.

## Impact

- Daemon-closure failures retain the root, process, endpoint, registry, and log
  context available at the failure boundary.
- Incident files preserve request and lifecycle evidence after the daemon is no
  longer available to answer introspection calls.
- Remaining setup/build phase visibility is tracked separately as structured
  Lean file-worker progress.

## Beam Decision

Archived. The narrow failure-reporting and incident-record slice landed in
[PR #194](https://github.com/ejgallego/lean-beam/pull/194) and
[PR #195](https://github.com/ejgallego/lean-beam/pull/195). Do not reopen this
card as a broad daemon metrics or orchestration project; track a new minimized
failure separately if issue 110 produces fresh evidence.

## Reproduction Status

The intermittent failure itself was not reproduced during the roadmap review.
Current regression coverage in `BeamTest.Broker.CliDaemonTest` exercises
enriched close failures, incident creation, retention, and unavailable-daemon
context. Issue [lean-beam#110](https://github.com/ejgallego/lean-beam/issues/110)
remains the evidence location for any fresh CI occurrence.

## Preliminary Analysis

The implemented daemon incident path survives connection closure, records the
available daemon registry and log context, and keeps a bounded set of incident
files under the Beam control directory. This resolves the card's Beam-owned
failure-reporting slice without changing daemon scheduling policy.

Related but separable work: structured `lake setup-file` dependency-build
progress is tracked in
[ULC-0003](../ULC-0003-structured-setup-file-progress/README.md). Beam should
not wait for that upstream improvement before making daemon-side incidents more
actionable.

## Expected Behavior

Beam should keep failures reportable:

- attach registry and log context to daemon-closure errors;
- preserve bounded incident records after daemon disappearance;
- retain enough request and process identity to produce a useful feedback
  report;
- keep setup/build progress work separate from incident persistence.

## Evidence

Imported from the LIRIS card set. Raw logs, strace output, and gdb artifacts
were not copied into this public repository.

Related Beam issue: [lean-beam#110](https://github.com/ejgallego/lean-beam/issues/110)
tracks intermittent MCP bridge-ready CI timeouts and the diagnostic context
needed for those occurrences.

## Current Workaround

Use `lean-beam doctor` and the recent incident paths it reports when a daemon
disappears. Attach the relevant incident JSON through `lean-beam feedback` or
MCP `beam_feedback` when filing a fresh minimized report.
