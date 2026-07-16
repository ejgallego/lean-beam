# MCP

This is maintainer documentation for the experimental `lean-beam-mcp` server. User setup lives in
the [setup guide](SETUP.md#mcp-setup).

## Current Shape

`lean-beam-mcp` is a stdio MCP server over the shared Beam layer. It is not a raw Lean LSP proxy and
does not auto-expose editor-oriented LSP methods as agent tools.

The layering is:

- [Beam/LSP/RunAt.lean](../Beam/LSP/RunAt.lean) owns the small Lean extension request and response
  types.
- [Beam/Broker/Protocol.lean](../Beam/Broker/Protocol.lean) owns the local broker request, response,
  and stream envelopes.
- [Beam/Broker/Server.lean](../Beam/Broker/Server.lean) owns workspace and session lifecycle,
  document sync, save barriers, cancellation, backend dispatch, and the shared in-process runtime
  used by both the daemon transport and MCP server.
- [Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) owns curated Lean operations, typed inputs,
  JSON schemas, and operation-to-broker adapters.
- [Beam/Cli/LeanOperation.lean](../Beam/Cli/LeanOperation.lean) owns the matching CLI projection for
  public Lean operations.
- [Beam/Workspace/Protocol.lean](../Beam/Workspace/Protocol.lean) owns typed workspace ids and the
  shared workspace initialization input, mode, and result shapes.
- [Beam/Workspace.lean](../Beam/Workspace.lean) owns shared workspace setup errors and active-root
  metadata.
- [Beam/Lean/Workspace.lean](../Beam/Lean/Workspace.lean) owns Lean/Lake project-root validation for
  CLI and MCP setup paths.
- [Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean) owns MCP tool names, descriptors, and
  normalized agent-facing output shapes.
- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean) owns MCP JSON-RPC and tool-result helpers.
- [Beam/Mcp/Options.lean](../Beam/Mcp/Options.lean), [Beam/Mcp/Roots.lean](../Beam/Mcp/Roots.lean),
  [Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean), and
  [Beam/Mcp/SelfCheck.lean](../Beam/Mcp/SelfCheck.lean) own executable setup boundaries.
- [Beam/Mcp/Server.lean](../Beam/Mcp/Server.lean) owns the broker-backed stdio MCP server.
- [Beam/Mcp/ServerMain.lean](../Beam/Mcp/ServerMain.lean) owns the `lean-beam-mcp` executable entry
  point.

The MCP server sits beside the CLI as another projection over the same Beam operation set. It is a
broker-runtime-backed executable, not a second client process that talks to the Beam daemon.

## Runtime Setup

The installed `bin/lean-beam-mcp` wrapper is the public setup path. It pairs the MCP executable with
the matching installed `beam-cli` and passes `--beam-cli`; after root selection,
[Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean) asks `beam-cli --root <root> mcp-config` for the
project-specific Lean command and runAt plugin.

Keep bundle resolution in the CLI/runtime boundary. Do not duplicate installed-bundle selection
inside the MCP server, and do not make normal MCP clients pass raw Lean plugin paths.

`--root PATH` is supported as the explicit default workspace root. Without `--root`, the server
discovers the default root through exactly one `file://` MCP `roots/list` result, or through an
explicit `lean_init_workspace` call before the first default-workspace Lean tool. Clients can add
additional local workspaces by calling `lean_init_workspace` with `workspace_id`; subsequent Lean
tools may pass the same optional `workspace_id` to route a request to that workspace. Omitting
`workspace_id` means the default workspace.

The `--root` startup flag accepts absolute paths and paths relative to the server's current working
directory. The `lean_init_workspace` tool intentionally accepts only absolute Lean/Lake project
roots, because it is a client API and should not depend on the server process cwd.

`lean_init_workspace` supports `mode: "set"`, `mode: "verify"`, and `mode: "reset"`. Reset replaces
only the selected workspace id and invalidates handles from that workspace. Keep the shared typed
input/result shape in [Beam.Workspace.Protocol](../Beam/Workspace/Protocol.lean) and the ownership
policy in the broker workspace lifecycle; do not duplicate root-switching policy in the MCP server.
Successful initialization results include a `capabilities` array naming projected MCP tool names;
derive those names from the operation/projection layer instead of maintaining a separate hand-written
capability list.

Direct developer runs of `.lake/build/bin/lean-beam-mcp` may still pass `--lean-cmd` and
`--lean-plugin` explicitly.

## Client Tool Semantics

`tools/list` includes the setup tool `lean_init_workspace`, workspace lifecycle tools
`lean_list_workspaces` and `lean_drop_workspace`, the Beam utility tools `beam_version`,
`beam_stats`, and `beam_feedback`, and the Lean operation tools projected from
`Beam.Lean.Operation`. `lean_drop_workspace` requires an explicit `workspace_id`; pass
`"default"` to drop the default workspace. Successful
`lean_init_workspace` results include a `capabilities` array for the post-initialization tools:
`beam_version`, `beam_stats`, `beam_feedback`, `lean_list_workspaces`, `lean_drop_workspace`,
`lean_update`, `lean_sync`, `lean_refresh`, `lean_save`, `lean_close_save`, `lean_close`,
`lean_run_at`, `lean_run_at_handle`, `lean_run_with`, `lean_run_with_linear`, `lean_release`,
`lean_hover`, `lean_signature_help`, `lean_definition`, `lean_references`,
`lean_document_symbols`, `lean_workspace_symbols`, `lean_goals`, `lean_todo`, and
`lean_code_action_resolve`.

Direct MCP clients should call `lean_update` before snapshot-bound tools such as `lean_run_at`,
`lean_run_at_handle`, `lean_hover`, `lean_signature_help`, `lean_definition`, `lean_references`,
`lean_document_symbols`, `lean_goals`, `lean_todo`, and `lean_code_action_resolve`; those calls
require the `version` returned by a successful `lean_update` or `lean_sync` for the same path.
`lean_workspace_symbols` is workspace-scoped and does not take a file version. When multiple
workspaces are initialized, pass `workspace_id` to select the symbol workspace. `lean_run_with`,
`lean_run_with_linear`, and `lean_release` use an opaque handle returned by a previous handle tool
result rather than a document version; handles carry their workspace identity and are rejected if a
conflicting explicit `workspace_id` is supplied. `lean_goals` also requires `mode: "before"` or
`mode: "after"`.

`lean_code_action_resolve` takes a `code_action` payload previously returned by `lean_todo`. Clients
apply any returned LSP `WorkspaceEdit` themselves, then call `lean_update` or `lean_sync` again so
Beam observes the edited file and reports the new version. Use `lean_sync` instead of `lean_update`
when the client also needs the diagnostics/readiness barrier.

`lean_save` and `lean_close_save` create development checkpoints from the accepted Lean server
snapshot. Their success is normally sufficient for the local development loop, but MCP clients
should describe it as checkpoint success rather than batch-build or CI success. CI must separately
run `lake build` from clean artifacts. If no successful clean CI result is available, perform the
one-time clean local check outside MCP. See the
[checkpoint contract](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).

## Public Tool Boundary

Add MCP-facing Lean behavior through the shared operation layer first:

1. Add or reuse a `Beam.Lean.Operation`.
2. Add a `ToolName` only if the operation is meant to be a public agent tool.
3. Map to broker operations through the shared operation helpers.
4. If the operation also belongs on the CLI, project it through `Beam.Cli.LeanOperation`.
5. Normalize MCP output names in the projection, for example `next_handle` and `proof_state`.

Keep raw LSP methods and params out of MCP input types. Do not expose expert or raw escape hatches
such as `lean-request-at` as MCP tools. The project root belongs in server/session context, not in
each tool input.

## Protocol And Errors

`Beam.Mcp.protocolVersion` is the only MCP revision advertised during initialization. The current
server advertises `2025-11-25` only. Bump it, or add support for another revision, only with a
protocol audit: check the upstream MCP schema/changelog, update local protocol tests, run the
Lean-backed stdio harness, update this document and any affected status notes, and run
[tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh) against the revised conformance
baseline.

The server follows the `2025-11-25` tool-call error split:

- malformed or unknown tools are JSON-RPC protocol errors
- invalid inputs for known tools return MCP tool execution errors with `isError=true`
- Lean semantic failures remain normal successful tool returns with Lean-specific success fields

The product entry point is stdio. The local Streamable HTTP bridge in
[tests/mcp_http_bridge.py](../tests/mcp_http_bridge.py) is a test/conformance adapter over the stdio
server, not a separate product transport.

## Progress And Diagnostic Logs

The MCP server advertises logging and progress capabilities. Client-facing reporting surfaces stay
separate:

| Surface | Transport | Meaning |
| --- | --- | --- |
| Progress | `notifications/progress` | Request-scoped operation movement for clients that pass `_meta.progressToken`. |
| Diagnostics | `notifications/message` with logger `lean.diagnostic` | Incremental Lean diagnostics observed while a sync/save-style request is pending. |
| Readiness | Final structured tool result | Stable synced-state verdict for the document version, including save readiness and counts. |

For `tools/call`, clients can pass `params._meta.progressToken` as a string or integer. The server
emits monotonic `notifications/progress` updates for request setup, execution phases, and throttled
Lean `fileProgress` details before the final response is sent.

Lean diagnostics are not encoded as progress notifications. Sync/save-style tools forward
incremental Lean diagnostics as structured `notifications/message` events with path, URI, version,
range, severity, and message data. Diagnostics known to block file completion carry
`completionBlocking=true`. Save-blocking evidence is reported on the final sync/save verdict through
`blockingDiagnostics` and `blockingCommandMessages`; earlier diagnostic log events are not
retroactively rewritten.

MCP clients that cannot conveniently collect interleaved notifications can call `lean_sync` with
`include_diagnostics: true` to also include the current request diagnostics in
`structuredContent.diagnostics`. Combine it with `full_diagnostics: true` when the reply should
include warnings, information, and hints instead of the default error-only diagnostic filter.

## Testing And Conformance

Use the MCP checks as layered gates:

- [BeamTest/Broker/McpProjectionTest.lean](../tests/lean/BeamTest/Broker/McpProjectionTest.lean): projection
  boundary, public tool names, raw-LSP rejection, typed operation adapters, root-free Lean operation
  inputs, setup tools, and normalized output fields.
- [BeamTest/Broker/McpProtocolTest.lean](../tests/lean/BeamTest/Broker/McpProtocolTest.lean): JSON-RPC shapes,
  generated schemas, lifecycle gating, roots helpers, workspace lifecycle schemas, setup errors, and
  tool input validation.
- [tests/test-mcp-stdio.py](../tests/test-mcp-stdio.py): real stdio process behavior over a copied
  Lean fixture project, including explicit `--root`, relative `--root`, `lean_init_workspace`,
  roots discovery, workspace list/drop, reset, and handle invalidation paths.
- [tests/test-mcp-http-bridge.py](../tests/test-mcp-http-bridge.py): deterministic Streamable HTTP
  bridge behavior over a stdio child.
- [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh): pinned external conformance
  scenarios against the local HTTP bridge.
- [tests/test-beam-fast.sh](../tests/test-beam-fast.sh): the quick maintainer gate for MCP
  projection, protocol-only checks, one Lean-backed stdio pass, HTTP bridge smoke, and self-check.
- [tests/test-beam-slow.sh](../tests/test-beam-slow.sh): repeated MCP server restarts and real
  tool calls.
- [tests/test-beam-install.sh](../tests/test-beam-install.sh): installed runtime layout, installed MCP wrapper
  resolution, and installed MCP self-check.

The default conformance package is pinned in
[tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh). Changing the package version,
advertised protocol revision, or scenario baseline is a protocol change. Update this document,
[docs/TESTING.md](TESTING.md), and the CI workflow as needed.

Some official conformance scenarios are fixture-specific. For example, `json-schema-2020-12` checks
for a special tool named `json_schema_2020_12_tool`; it does not merely validate that every real
server tool uses draft 2020-12. Tool-call scenarios likewise expect conformance fixture tools unless
the server exposes compatible tools or carries an expected-failure baseline.

## Future Work

Current known MCP follow-ups:

- MCP cancellation notification handling
- remote workspace transports and same-source multi-toolchain mirrors
- richer progress percentages or bounded work-unit totals if Lean exposes them
- broader conformance scenarios when the server exposes the corresponding capabilities
- a first-class HTTP transport only if real users need HTTP
