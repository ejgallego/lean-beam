# ULC-0003 Structured File-Worker Progress

Status: deferred
Kind: upstream-api
Priority: medium
Origin: upstream Lean backlog
Last reviewed: 2026-07-07
Issue: none linked
Lean PR: none linked

## Summary

Lean file-worker `lake setup-file` progress is currently exposed as ordinary
information diagnostics with a synthetic file-start range. Beam recognizes Lake
build-monitor text so MCP and wrapper clients can see cold setup activity
during long syncs and `runAt` probes.

## Impact

- Matching diagnostic text is deliberately brittle.
- Progress appears through the same channel as user-facing diagnostics.
- Cold-start reporting is less structured than request progress should be.

## Beam Decision

Defer for 0.2.0 unless it becomes necessary for
[BUC-0006](../BUC-0006-cold-start-daemon-lifecycle/README.md). This is a good
upstream cleanup, but the release-critical work is making failures reportable
with the information Beam already has.

## Reproduction Status

No upstream Lean PR is linked yet. Beam currently has a narrow local matcher for
Lake build-monitor diagnostic text and tests around progress/readiness
separation.

## Preliminary Analysis

This should remain a cleanup card unless cold-start incidents prove that
string-matched setup progress is the blocker. Beam can improve daemon
tombstones and client-facing failure context without waiting for this upstream
progress API.

## Expected Behavior

Lean should expose typed setup/build progress through an LSP notification or
API that includes target/module caption, phase, completion/failure status, and
bounded detail text.

Beam would stop matching build-monitor diagnostic strings for progress.

## Evidence

The current workaround is documented in
[Development](../../../DEVELOPMENT.md#lean-api-workaround-notes), and the narrow
matcher lives near `Beam/Broker/SyncSaveSupport.lean`.

## Current Workaround

Keep string matching narrow and isolated. Do not use setup progress as a
readiness authority.
