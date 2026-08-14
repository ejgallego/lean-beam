# ULC-0004 Structured Lean Request Error Data

Status: open
Kind: upstream-api
Priority: medium
Origin: upstream Lean backlog
Last reviewed: 2026-07-08
Issue: none linked
Lean PR: none linked
Upstream timing: when the Lean `RequestError` API shape is clear

## Summary

Beam's public success payloads, including `runAt`, do not need upstream Lean
changes for this card. The concrete Beam surface is the existing
`Response.error.data?` envelope used by the broker, CLI, and MCP projections for
snapshot-bound request failures.

Beam sometimes rejects stale or invalid request states before forwarding to the
Lean plugin so it can attach machine-readable transport error data there. Some
of that would be cleaner if Lean's normal `RequestError` path could preserve
optional JSON-RPC error data instead of reducing failures to code and message.

## Impact

- Broker-side preflight can duplicate validation that belongs with the request
  owner.
- Plugin-level `contentModified` failures need machine-readable fields such as
  `documentVersionMismatch` when they cross the transport boundary.
- Snapshot-bound operations such as `run_at`, `hover`, `goals`, `todo`, and
  save/readiness checks all benefit from the same small `error.data` contract.
- Clients should not parse rendered exception text to recover control flow, and
  Beam should not need extra Beam-specific error codes just to carry retry data.

## Upstream Decision

Track as a Lean-cycle API quality card, not as a Beam release blocker. Beam
should keep local broker errors structured, and delete duplicated preflight or
reconstruction code only when Lean can carry equivalent typed JSON-RPC error
data through its regular request-error path.

## Reproduction Status

No upstream Lean PR is linked yet. Beam currently keeps its own broker-side
structured errors for stale versions and invalid request states. Lean's
low-level JSON-RPC response path can already carry `data?`; the missing piece is
the higher-level `RequestError` surface used by request handlers.

## Preliminary Analysis

This is useful cleanup, but Beam should not depend on it for local release
work. The local code smell to avoid is parsing rendered exception text; Beam
already has repo guidance to keep `Response`, `BrokerFailure`, and structured
error data typed across async boundaries.

The current Beam reason for broker-side enrichment is concrete: `run_at` and
nearby versioned requests can fail before or during Lean worker execution when
the client supplied a stale document version. The public failure should remain
`contentModified`, but `error.data` should carry typed retry facts such as
`reason`, `expectedVersion`, `acceptedVersion`, `currentVersion`, and `uri`.

## Expected Behavior

Lean `RequestError` should carry optional structured JSON-RPC error data for
transport-level failures, including stale document version, current version, and
typed reason codes. `RequestError.toLspResponseError` should preserve that data
when building the final response error.

Beam would forward those typed errors instead of reconstructing them at the
broker boundary. This should not change the `runAt` success payload.

## Evidence

- The current direction is summarized in [Status](../../../STATUS.md#direction).
- Beam's broker protocol already exposes `Response.error.data?` in
  [Beam/Broker/Protocol.lean](../../../../Beam/Broker/Protocol.lean).
- Beam's broker failures already keep optional structured data in
  [Beam/Broker/Errors.lean](../../../../Beam/Broker/Errors.lean).
- Beam's versioned request helpers currently need broker-side structured stale
  version responses in [Beam/Broker/Server.lean](../../../../Beam/Broker/Server.lean).
- Lean plugin helpers such as `requireDocumentVersion` can currently throw only
  code/message request errors from
  [Beam/LSP/Lib/Request.lean](../../../../Beam/LSP/Lib/Request.lean).

## Current Workaround

Keep Beam's own `Response`, `BrokerFailure`, and structured error data typed
across async boundaries, and stringify only at transport, CLI, or diagnostic
display edges.
