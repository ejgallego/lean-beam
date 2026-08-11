# MCP

This is maintainer documentation for the experimental `lean-beam-mcp` server. User setup lives in
the [setup guide](SETUP.md#mcp-setup).

## Current Protocol And State Model

`lean-beam-mcp` is a stdio MCP server over the shared Beam broker runtime. It is not a raw Lean LSP
proxy and does not auto-expose editor-oriented LSP methods as agent tools.

The server currently advertises MCP `2025-11-25` and requires `initialize` followed by
`notifications/initialized`. The application model is already request-stateless in preparation for
MCP `2026-07-28`:

- every workspace-bound request includes an explicit workspace descriptor
- no request depends on a root or workspace selected by earlier MCP traffic
- continuation state is explicit in proof handles
- warm Lean processes, document mirrors, metrics, and diagnostics remain implementation caches

The modern wire-protocol update is separate work. It will add `server/discover`, per-request
protocol metadata, modern result envelopes and caching hints, and request-scoped logging. MRTR
`requestState` is request-local continuation data and will not be used as a workspace identifier.

## Local Workspace Descriptor

The current local descriptor is:

```json
{
  "workspace": {
    "root": "/absolute/path/to/lean/project"
  }
}
```

`workspace` is required on `beam_feedback`, `lean_drop_workspace`, and every Lean operation. The
root must be an absolute path to an existing Lean/Lake project. Beam resolves it to a canonical path
and derives a private, deterministic broker cache key from that path. Canonical aliases therefore
share one runtime; clients do not choose process-local workspace ids.

There is no distinguished default workspace, `lean-beam-mcp --root`, `lean_init_workspace`,
`lean_list_workspaces`, or MCP `roots/list` fallback. A first ordinary request is sufficient:

```json
{
  "name": "lean_sync",
  "arguments": {
    "workspace": {"root": "/absolute/path/to/project"},
    "path": "Main.lean"
  }
}
```

The server validates the descriptor, lazily creates or reuses its runtime, and echoes the canonical
descriptor in successful Lean results:

```json
{
  "workspace": {"root": "/canonical/path/to/project"}
}
```

This is deliberately a local-only descriptor. Remote workspaces and same-source multiple-toolchain
mirrors need a broader Source/Workspace split and a transport-safe descriptor; they are not modeled
as client-chosen aliases for local roots.

## Runtime Setup

The installed `bin/lean-beam-mcp` wrapper is the public setup path. It pairs the MCP executable with
the matching installed `beam-cli` and passes `--beam-cli`. On first use of a canonical root,
[Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean) asks
`beam-cli --root <root> mcp-config` for the project-specific Lean command and runAt plugin.

Keep bundle resolution in this CLI/runtime boundary. Normal MCP clients should pass the workspace
descriptor, not raw Lean commands or plugin paths. Direct developer runs may still pass
`--lean-cmd` and `--lean-plugin` explicitly.

`lean_drop_workspace` is optional cache management, not context selection. It evicts the runtime
for its descriptor and invalidates proof handles owned by that runtime. Drop is idempotent and
returns `dropped: false` with `reason: "notFound"` when no cache exists. A later ordinary request
with the same descriptor recreates the runtime lazily.

After editing a lakefile, manifest, package override, `lean-toolchain`, Lean options, plugins, or
dynamic libraries, drop that workspace or restart the MCP server before the next request. Re-syncing
inside the old Lean process is not sufficient to reload workspace configuration.

## Code Ownership

- [Beam/Broker/Protocol.lean](../Beam/Broker/Protocol.lean) owns broker request, response, handle,
  and stream envelopes.
- [Beam/Broker/Server.lean](../Beam/Broker/Server.lean) owns workspace runtimes, document state,
  sessions, metrics, cancellation, and handle invalidation.
- [Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) owns curated Lean operations, typed inputs,
  schemas, and operation-to-broker adapters.
- [Beam/Workspace/Protocol.lean](../Beam/Workspace/Protocol.lean) owns the public local descriptor
  and broker-internal lifecycle types.
- [Beam/Lean/Workspace.lean](../Beam/Lean/Workspace.lean) owns Lean/Lake root validation.
- [Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean) owns MCP tool names, descriptors, schemas,
  and normalized output.
- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean) owns the current MCP JSON-RPC helpers.
- [Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean) owns root-to-runtime configuration.
- [Beam/Mcp/SelfCheck.lean](../Beam/Mcp/SelfCheck.lean) owns the installed-wrapper self-check.
- [Beam/Mcp/Server.lean](../Beam/Mcp/Server.lean) owns descriptor resolution, lazy cache dispatch,
  the separate legacy-protocol/application state records, and the synchronous protocol-test seam.
- [Beam/Mcp/StdioServer.lean](../Beam/Mcp/StdioServer.lean) owns the permanent stdin reader,
  concurrent coordination, cancellation, cache-control barriers, and serialized output.

## Public Tools

`tools/list` contains:

- process utilities: `beam_version`, `beam_stats`
- workspace-bound feedback: `beam_feedback`
- cache eviction: `lean_drop_workspace`
- curated Lean operations projected from `Beam.Lean.Operation`

The Lean operations include update/sync/refresh/save/close operations, runAt and explicit follow-up
handle operations, hover and navigation, document/workspace symbols, goals, todo discovery, and
code-action resolution. Raw LSP methods and generic broker escape hatches are intentionally absent.

`beam_version` returns the running server identity in `structuredContent`. Installed runtime
identities include the optional Boolean `runtime_current`: `true` means the process belongs to the
runtime selected by the install root's `current` link, while `false` means it is stale or that the
link is missing. Source-checkout identities omit this field. Invalid installed state also includes
the optional string `runtime_error`; the tool call still succeeds so clients can report the broken
identity. Restart an agent or MCP client for `runtime_current: false`. For `runtime_error`, stop Beam
clients and follow the error-specific
[installed-runtime recovery guidance](SETUP.md#prune-old-installed-state) before resuming normal
work.

Direct MCP clients should call `lean_update` or `lean_sync` before snapshot-bound operations and
pass the returned `version` for the same descriptor and path. `lean_workspace_symbols` is
workspace-scoped but has no document version. `lean_run_with`, `lean_run_with_linear`, and
`lean_release` take an opaque handle returned by a previous handle operation. The supplied workspace
descriptor must resolve to the same private runtime identity carried by that handle. `lean_goals`
also requires `mode: "before"` or `mode: "after"`.

Beam's source-file invariant is that Beam never applies source edits to `.lean` files on disk; the
client applies source edits. `lean_update`, `lean_sync`, and `lean_refresh` read the current saved
source from disk into Beam's LSP mirror. `lean_save` and `lean_close_save` additionally write
Lean/Lake build artifacts, never source. `lean_code_action_resolve` only returns a resolved action;
the client must apply any LSP `WorkspaceEdit` it contains.

`lean_run_at`, `lean_run_at_handle`, `lean_run_with`, and `lean_run_with_linear` are speculative.
They test supplied text against a selected document snapshot or follow-up handle without persisting
that text as source. Do not call `lean_sync` as a way to commit a successful probe. To keep a result,
first edit and save the Lean file with the client's normal file-editing tool. Then call `lean_update`
before another snapshot-bound operation, or call `lean_sync` when a diagnostics/readiness barrier is
needed. Both commands read the current on-disk file; neither applies or recovers speculative text.

`lean_code_action_resolve` takes a `code_action` payload previously returned by `lean_todo`. Clients
apply any returned LSP `WorkspaceEdit` themselves, then call `lean_update` or `lean_sync` again so
Beam observes the edited file and reports the new version. Use `lean_sync` instead of `lean_update`
when the client also needs the diagnostics/readiness barrier.

`lean_save` and `lean_close_save` create development checkpoints from the accepted Lean server
snapshot, including structured Lake options, dynamic libraries, and plugins already applied by the
file worker. Modules with batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`; move shared
`-D` settings to `leanOptions`, or use `lake build` when the arguments are intentionally batch-only.
Successful checkpoints are normally sufficient for the local development loop, but MCP clients
should describe them as checkpoint success rather than batch-build or CI success. CI must separately
run `lake build` from clean artifacts. If no successful clean CI result is available, perform the
one-time clean local check outside MCP. See the
[checkpoint contract](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).

The running Lean server is not guaranteed to pick up Lake workspace configuration changes. After
editing a lakefile, manifest, package override, `lean-toolchain`, Lean options, plugins, or dynamic
libraries, drop that workspace or restart the MCP server before the next request. Calling
`lean_sync` in the existing runtime is not sufficient.

## Process-Wide Utilities And Feedback

`beam_version` and `beam_stats` are process-wide and accept no workspace descriptor. `beam_stats`
reports all currently cached broker workspaces for debugging; callers must not use it to establish
context for a later operation.

`beam_feedback` requires a descriptor because it collects project and runtime context for one
workspace. It does not start a Lean runtime solely to collect feedback. If that descriptor is
already cached, its in-process stats and open files are included; another workspace's state is not.

## Protocol Errors

For MCP `2025-11-25`:

- malformed or unknown tools are JSON-RPC errors
- invalid inputs for known tools are MCP tool errors with `isError=true`
- invalid, missing, relative, or non-project workspace roots are structured `invalidInput` errors
- Lean semantic failures remain successful tool returns with Lean-specific success fields
- stale or cross-workspace handles remain structured transport/tool errors

## Concurrency, Cancellation, And Shutdown

The server has one permanent stdin reader and one serialized stdout sink. Ordinary tool calls may
overlap, and responses may arrive out of request order. Clients must correlate exact JSON-RPC IDs;
string and numeric IDs are distinct.

The server never sends JSON-RPC requests to the client. Under the current protocol it emits only
responses and request-related notifications. In particular, descriptor resolution never invokes
MCP Roots.

`notifications/cancelled` cooperatively cancels active broker work. If cancellation wins the
terminal race, no final response is emitted for that request. `lean_drop_workspace` is
non-cancellable once admitted because partial cache eviction cannot be rolled back safely. Cache
control is ordered with later calls: a request queued after a drop observes the completed eviction
and may immediately recreate the same descriptor.

EOF is the normal transport shutdown. The current legacy `shutdown` request is also supported.

## Progress And Diagnostic Logs

For `tools/call`, clients may pass `params._meta.progressToken` as a string or integer. Progress
updates for one request are monotonic and precede that request's final response.

Incremental Lean diagnostics are separate `notifications/message` events with logger
`lean.diagnostic`. Clients that cannot collect interleaved notifications can pass
`include_diagnostics: true` to sync-style tools. Use `full_diagnostics: true` when the final reply
should include warnings, information, and hints rather than only errors.

The current global `logging/setLevel` behavior belongs to the `2025-11-25` path. The modern protocol
update will make logging request-scoped.

## Testing And Conformance

- [McpProjectionTest.lean](../tests/lean/BeamTest/Broker/McpProjectionTest.lean) checks the curated
  tool surface, descriptor schemas, adapters, and normalized results.
- [McpProtocolTest.lean](../tests/lean/BeamTest/Broker/McpProtocolTest.lean) checks JSON-RPC shapes,
  descriptor decoding, lifecycle gating, progress, errors, and diagnostic forwarding.
- [test-mcp-stdio.py](../tests/test-mcp-stdio.py) checks real lazy first use, canonical aliases,
  concurrent multi-root isolation, cross-workspace handles, scoped feedback, eviction/recreation,
  cancellation, response routing, progress, and shutdown.
- [test-mcp-http-bridge.py](../tests/test-mcp-http-bridge.py) checks the local test-only HTTP adapter.
- [test-mcp-conformance.sh](../tests/test-mcp-conformance.sh) runs the pinned external conformance
  scenarios supported by the current protocol.

The Streamable HTTP bridge is a test adapter over the stdio product, not a separate deployment
model. Remote and load-balanced deployment requires an explicit transport-safe workspace design and
must not infer application identity from a connection.
