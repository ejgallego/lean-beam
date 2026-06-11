# MCP

This is maintainer documentation for the experimental `lean-beam-mcp` server. User setup lives in
the [setup guide](SETUP.md#mcp-setup). Historical design background lives in the
[archived MCP plan](archive/MCP_PLAN.md).

## Current Shape

`lean-beam-mcp` is a stdio MCP server over the shared Beam layer. It is not a raw Lean LSP proxy and
does not auto-expose editor-oriented LSP methods as agent tools.

The layering is:

- [RunAt/Protocol.lean](../RunAt/Protocol.lean) owns the small Lean extension request and response
  types.
- [Beam/Broker/Protocol.lean](../Beam/Broker/Protocol.lean) owns the local broker request, response,
  and stream envelopes.
- [Beam/Broker/Server.lean](../Beam/Broker/Server.lean) owns session lifecycle, document sync, save
  barriers, cancellation, backend dispatch, and the shared in-process runtime used by both the daemon
  transport and MCP server.
- [Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) owns curated Lean operations, small typed
  inputs, JSON schemas, and operation-to-broker adapters.
- [Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean) owns MCP tool names, descriptors, and
  normalized agent-facing output shapes.
- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean) owns MCP JSON-RPC and tool-result helpers.
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

`--root PATH` is supported as an explicit single-root override. Without `--root`, the server discovers
the project root through exactly one `file://` MCP `roots/list` result. Multiple roots are rejected
for now, so clients that expose more than one workspace should pass `--root`.

Direct developer runs of `.lake/build/bin/lean-beam-mcp` may still pass `--lean-cmd` and
`--lean-plugin` explicitly.

## Public Tool Boundary

Add MCP-facing Lean behavior through the shared operation layer first:

1. Add or reuse a `Beam.Lean.Operation`.
2. Add a `ToolName` only if the operation is meant to be a public agent tool.
3. Map to broker operations through the shared operation helpers.
4. Normalize MCP output names in the projection, for example `next_handle` and `proof_state`.

Keep raw LSP methods and params out of MCP input types. Do not expose expert or raw escape hatches
such as `lean-request-at` as MCP tools. The project root belongs in server/session context, not in
each tool input.

## Protocol And Errors

`Beam.Mcp.protocolVersion` is the only MCP revision advertised during initialization. The current
server advertises `2025-11-25` only. Bump it, or add support for another revision, only with a
protocol audit: check the upstream MCP schema/changelog, update local protocol tests, run the
Lean-backed stdio harness, update [docs/STATUS.md](STATUS.md), and run
[tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh) against the revised conformance
baseline.

The server follows the `2025-11-25` tool-call error split:

- malformed or unknown tools are JSON-RPC protocol errors
- invalid inputs for known tools return MCP tool execution errors with `isError=true`
- Lean semantic failures remain normal successful tool returns with Lean-specific success fields

The product entry point is stdio. The local Streamable HTTP bridge in
[tests/mcp_http_bridge.py](../tests/mcp_http_bridge.py) is a test/conformance adapter over the stdio
server, not a separate product transport.

## Testing And Conformance

Use the MCP checks as layered gates:

- [RunAtTest/Broker/McpProjectionTest.lean](../RunAtTest/Broker/McpProjectionTest.lean): projection
  boundary, public tool names, raw-LSP rejection, typed operation adapters, root-free inputs, and
  normalized output fields.
- [RunAtTest/Broker/McpProtocolTest.lean](../RunAtTest/Broker/McpProtocolTest.lean): JSON-RPC shapes,
  generated schemas, lifecycle gating, roots helpers, setup errors, and tool input validation.
- [tests/test-mcp-stdio.py](../tests/test-mcp-stdio.py): real stdio process behavior over a copied
  Lean fixture project.
- [tests/test-mcp-http-bridge.py](../tests/test-mcp-http-bridge.py): deterministic Streamable HTTP
  bridge behavior over a stdio child.
- [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh): pinned external conformance
  scenarios against the local HTTP bridge.
- [tests/test-broker-fast.sh](../tests/test-broker-fast.sh): the quick maintainer gate for MCP
  projection, protocol-only checks, one Lean-backed stdio pass, HTTP bridge smoke, and self-check.
- [tests/test-broker-slow.sh](../tests/test-broker-slow.sh): repeated MCP server restarts and real
  tool calls.
- [tests/test-install.sh](../tests/test-install.sh): installed runtime layout, installed MCP wrapper
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

- live MCP progress forwarding during long-running calls
- MCP cancellation notification handling
- broader conformance scenarios when the server exposes the corresponding capabilities
- a first-class HTTP transport only if real users need HTTP
