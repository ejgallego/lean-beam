# ULC-0005 Pure Frontend Readiness Report

Status: deferred
Kind: upstream-api
Priority: medium
Origin: upstream Lean backlog
Last reviewed: 2026-07-07
Issue: none linked
Lean PR: none linked

## Summary

Beam needs a cheap way to ask Lean frontend state for the build-blocking
decision and diagnostic counts without printing messages. Today Beam composes
nearby APIs and barrier observations.

## Impact

- Readiness reporting spans multiple channels.
- Beam must be careful not to treat printed diagnostics or progress as the
  semantic authority.
- A pure helper would simplify sync summaries and save preflight reporting.

## Beam Decision

Defer for 0.2.0 unless the backend readiness primitive splits this into a
smaller upstream change. It is useful, but less directly release-blocking than
stale dependency metadata.

## Reproduction Status

No upstream Lean PR is linked yet. Current Beam tests cover the sync summary
and readiness projection that would consume such a helper.

## Preliminary Analysis

This overlaps with ULC-0002 and may be better folded into that card unless a
specific Lean helper emerges. Keep it deferred to avoid splitting upstream asks
too early.

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
