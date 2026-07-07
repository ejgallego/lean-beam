# ULC-0004 Structured Lean Request Error Data

Status: deferred
Kind: upstream-api
Priority: medium
Origin: upstream Lean backlog
Last reviewed: 2026-07-07
Issue: none linked
Lean PR: none linked

## Summary

Beam sometimes rejects stale or invalid request states before forwarding to the
Lean plugin so it can attach machine-readable transport error data. Some of
that would be cleaner if upstream Lean request failures could carry structured
JSON-RPC error data directly.

## Impact

- Broker-side preflight can duplicate validation that belongs with the request
  owner.
- Plugin-level `contentModified` failures need machine-readable fields such as
  `documentVersionMismatch`.
- Clients should not parse rendered exception text to recover control flow.

## Beam Decision

Defer for 0.2.0 unless it unblocks another scoped failure-reporting fix. This
is an upstream API quality card, not a new Beam user-facing surface.

## Reproduction Status

No upstream Lean PR is linked yet. Beam currently keeps its own broker-side
structured errors for stale versions and invalid request states.

## Preliminary Analysis

Keep this deferred. It is useful cleanup, but Beam should not depend on it for
0.2.0. The local code smell to avoid is parsing rendered exception text; Beam
already has repo guidance to keep `Response`, `BrokerFailure`, and structured
error data typed across async boundaries.

## Expected Behavior

Lean request handlers should be able to return structured JSON-RPC error data
for transport-level failures, including stale document version, current version,
and typed reason codes.

Beam would forward those typed errors instead of reconstructing them at the
broker boundary.

## Evidence

The current direction is summarized in [Status](../../../STATUS.md#direction).

## Current Workaround

Keep Beam's own `Response`, `BrokerFailure`, and structured error data typed
across async boundaries, and stringify only at transport, CLI, or diagnostic
display edges.
