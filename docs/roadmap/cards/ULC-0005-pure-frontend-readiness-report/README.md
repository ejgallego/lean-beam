# ULC-0005 Pure Frontend Readiness Report

Status: superseded
Kind: upstream-api
Priority: medium
Origin: upstream Lean backlog
Last reviewed: 2026-07-08
Issue: none linked
Lean PR: none linked
Upstream timing: folded into ULC-0002

## Summary

Beam needs a cheap way to ask Lean frontend state for the build-blocking
decision and diagnostic counts without printing messages. Today Beam composes
nearby APIs and barrier observations.

## Impact

- Readiness reporting spans multiple channels.
- Beam must be careful not to treat printed diagnostics or progress as the
  semantic authority.
- A pure helper would simplify sync summaries and save preflight reporting.

## Upstream Decision

Superseded by
[ULC-0002](../ULC-0002-backend-readiness-primitive/README.md). Do not track a
separate Lean PR for this card unless the readiness umbrella splits into a
specific pure-frontend helper proposal.

## Reproduction Status

No upstream Lean PR is linked yet. Current Beam tests cover the sync summary
and readiness projection that would consume such a helper.

## Preliminary Analysis

This overlaps with ULC-0002 and is now folded into that card. A pure helper
near `SnapshotTree.runAndReport` may still be the right implementation slice,
but it should be tracked from ULC-0002 until the upstream PR shape is concrete.

## Expected Behavior

Lean should expose a helper close to `SnapshotTree.runAndReport`, but returning
structured build-blocking decision data, diagnostic counts, and messages
without printing.

Beam would use it to simplify sync summaries and avoid reconstructing frontend
readiness from multiple observations.

## Evidence

The current direction is summarized in [Status](../../../STATUS.md#direction).

## Current Workaround

Keep the sync summary schema explicit, and document progress, streamed
diagnostics, and current readiness as separate concepts.
