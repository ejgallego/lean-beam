# MCP Plan

## Goal

Build a generic way to expose a useful MCP server from an LSP-style specification, without forcing a
bad one-to-one translation from editor methods to agent tools.

The target is not:

- auto-expose every LSP method as an MCP tool
- treat the raw LSP surface as the public agent interface

The target is:

- generic JSON-RPC and LSP runtime
- generic typed method/schema handling
- a small projection layer that maps selected LSP methods into good MCP tools

## Core View

LSP and MCP solve different problems.

- LSP is editor-centric, document-centric, and stateful
- MCP is agent-centric, task/tool-centric, and wants compact, discoverable operations

So the right abstraction is a projection framework:

1. typed protocol definitions
2. reusable LSP runtime
3. declarative MCP projection config

## What Should Be Generic

- JSON-RPC transport
- LSP process lifecycle
- initialize / shutdown
- request / response plumbing
- cancellation
- document open / change / close
- progress forwarding
- error mapping
- JSON schema generation for MCP tools

## What Should Stay Manual

- which methods are exposed
- tool names
- input/output compression
- hidden state management policy
- whether something is a tool, resource, or notification
- which editor-oriented fields should be removed from the agent-facing surface

## Current Status In This Repository

The current code now has a first executable MCP path plus the projection boundary it depends on:

- `RunAt/Protocol.lean` owns the small Lean extension request/response types.
- `Beam/Broker/Protocol.lean` owns the local broker request/response and stream envelopes.
- `Beam/Broker/Server.lean` owns session lifecycle, document sync, save barriers, cancellation,
  backend dispatch, and the shared in-process `ServerRuntime.dispatchRequest` path used by both the
  daemon transport and MCP server.
- `Beam/Cli.lean` and `scripts/lean-beam` adapt broker operations into the public shell workflow.
- `Beam/Lean/Operation.lean` owns the first shared Lean operation substrate: curated public
  operations, small typed inputs, JSON schemas, and operation-to-broker request adapters.
- `Beam/Mcp/Projection.lean` owns the MCP projection over that substrate: supported Lean tool
  names, tool descriptors, and normalized agent-facing output shapes.
- `Beam/Mcp/Protocol.lean` owns the small MCP JSON-RPC/tool-result protocol helpers.
- `Beam/Mcp/Server.lean` owns the experimental newline-delimited stdio MCP server.
- `Beam/Broker/ServerMain.lean` and `Beam/Mcp/ServerMain.lean` keep executable entry points separate
  from importable runtime modules.

The MCP server sits beside the CLI as another projection over the broker/public operation set, not
inside the raw LSP runtime and not as an automatic mirror of LSP methods. It is a broker-owned stdio
executable (`lean-beam-mcp`) rather than a separate client process that talks back to the daemon.
Broker responses now include an explicit `ok` boolean and structured `error` object, while still
accepting older inferred-`ok` responses on input. That gives an MCP projection a stable place to
separate transport/tool errors from normal Lean semantic failures such as `result.success=false`.

`lean-beam-mcp` currently advertises MCP protocol revision `2025-11-25` and intentionally does not
advertise older revisions. Version support should stay narrow, so every advertised revision has
explicit protocol, schema, error-shape, and external conformance tests.
The server accepts `--root` as an explicit single-root override. Without `--root`, clients can either
call `lean_init_workspace` with an absolute Lean/Lake project root or let the server ask for exactly
one `file://` root through MCP `roots/list`. That keeps project root selection in MCP session setup
rather than in individual Lean operation inputs. The init input, result shape, active-root metadata,
and reset policy live in the shared `Beam.Workspace` layer; Lean/Lake root validation lives in
`Beam.Lean.Workspace`. CLI and MCP project those shared pieces instead of carrying separate
workspace/session contracts.

## Proposed Architecture

### 1. Protocol Layer

Input:

- LSP spec, metamodel, or local typed protocol definitions

Responsibilities:

- represent methods, params, results, notifications, and error codes
- generate JSON schema for tool input/output
- preserve enough type information to build adapters safely

### 2. Runtime Layer

Responsibilities:

- start and stop the LSP server
- manage one session per project root
- manage document lifecycle
- send requests and receive responses
- handle cancellation
- subscribe to notifications and progress

This layer should know nothing about MCP naming or public tool design.

### 3. Projection Layer

Responsibilities:

- choose which LSP methods become MCP tools
- transform MCP input into LSP params
- transform LSP results into MCP output
- map selected notifications into MCP progress/events
- enforce preconditions like “document must be synced first”

This is the key layer. It is where the public agent interface is designed.

## Suggested Projection Config Shape

Illustrative sketch:

```yaml
tools:
  - name: lean_run_at
    lsp_method: "$/lean/runAt"
    input_map:
      path: textDocument.uri
      line: position.line
      character: position.character
      text: text
    output_map:
      success: success
      messages: messages
      traces: traces
      proof_state: proofState
      next_handle: handle
    progress:
      notification: "$/lean/fileProgress"

  - name: lean_run_with
    lsp_method: "$/lean/runWith"
    ...
```

This should be declarative where possible, with small escape hatches for custom transforms.

## Why `runAt` Is A Good First Backend

`runAt` is a strong first case because the useful surface is already small and typed:

- `$/lean/runAt`
- `$/lean/runWith`
- `$/lean/releaseHandle`
- `$/lean/fileProgress`

It also has real complexity:

- handle continuation
- linear vs non-linear state evolution
- progress reporting
- stale-state invalidation

So it is large enough to validate the design, but small enough to avoid building a giant generic
system too early.

## Recommended `runAt` MCP Surface

Do not expose raw LSP directly.

Start with these MCP tools:

- `lean_run_at`
- `lean_run_at_handle`
- `lean_hover`
- `lean_goals_after`
- `lean_goals_prev`
- `lean_run_with`
- `lean_run_with_linear`
- `lean_release`
- `lean_sync`
- `lean_deps`
- `lean_save`
- `lean_close`

The repository now implements an experimental `lean-beam-mcp` stdio server for this curated tool
set. New agent-facing Lean operations should be added to `Beam/Lean/Operation.lean` first, then
projected to MCP with an explicit `ToolName` only when they are meant to be public MCP tools. The
raw `lean-request-at` escape hatch should stay out of the MCP surface.

Lean operation tool inputs should not carry `root`; the MCP server session supplies the project root
from `lean_init_workspace`, the explicit `--root` override, or a single MCP `roots/list` result.
That keeps normal tool calls compact and avoids teaching agents to manage per-call broker session
state. `lean_init_workspace` itself is a projection of the shared Beam workspace/session setup
operation, not a Lean semantic operation and not a raw broker/LSP escape hatch.

Possible second phase:

- `lean_search_mint`
- `lean_search_branch`
- `lean_search_playout`
- `lean_search_release`

Those could sit on top of the existing search helper instead of exposing lower-level handle flows to
every client.

## Output Design

MCP output should be normalized for agents, not copied mechanically from the LSP payload.

Example shape for `lean_run_at`:

```json
{
  "success": true,
  "messages": [],
  "traces": [],
  "proof_state": { "goals": [] },
  "next_handle": null,
  "file_progress": {
    "updates": 10,
    "maxProcessing": 3,
    "finalProcessing": 1,
    "finalFatalErrors": 0,
    "done": false
  }
}
```

Rules:

- transport errors stay tool errors
- semantic Lean failures stay normal successful tool returns with `success = false`
- use `next_handle`, not raw `handle`, in the public MCP output
- keep `proof_state` as the agent-facing field name even though the Lean extension payload uses
  `proofState`

## Progress Model

Phase 1:

- return final `file_progress` in tool results

Phase 2:

- forward live progress as MCP progress/events during execution

The runtime should support both, but phase 1 is enough for a first useful server.

## Conformance Plan

The official MCP conformance runner tests servers through a Streamable HTTP URL, for example
`npx @modelcontextprotocol/conformance server --url http://localhost:3000/mcp`. The product
`lean-beam-mcp` implementation is stdio-only, so conformance currently goes through a test-only
bridge:

- `tests/mcp_http_bridge.py` hosts a localhost Streamable HTTP endpoint and forwards requests to a
  child `lean-beam-mcp` stdio process
- `tests/test-mcp-http-bridge.py` checks deterministic HTTP transport behavior without npm
- `tests/test-mcp-conformance.sh` is the external conformance runner around the pinned
  `@modelcontextprotocol/conformance@0.1.16` package; its default scenario set is
  `server-initialize`, `ping`, and `tools-list`, and CI runs that set on Ubuntu and macOS
- longer-term: a first-class HTTP transport module can be added if real users need HTTP, still
  sharing the broker-owned protocol/projection code with stdio

The conformance gate should be version-scoped:

- run the active server scenarios against the protocol revision advertised by
  `Beam.Mcp.protocolVersion`
- include the negotiated `MCP-Protocol-Version` header on HTTP requests once a bridge exists
- keep expected failures explicit for capabilities the server does not advertise, such as resources
  and prompts
- fail when an expected failure starts passing, so the baseline cannot become stale
- treat `server-initialize`, `tools-list`, and selected `tools-call-*` scenarios as required before
  considering the MCP server non-draft
- keep the npm-backed conformance job separate from the local deterministic bridge smoke so network
  or package-resolution failures do not obscure local MCP regressions
- do not mistake fixture-specific scenarios, such as `json-schema-2020-12` or generic
  `tools-call-*` fixture tools, for validation of the real Lean Beam tool surface unless a dedicated
  compatibility tool or expected-failure baseline is in place

Local deterministic tests should remain the first line of defense because they can exercise Lean
project roots, plugin loading, handle behavior, stale-state behavior, and shutdown/restart loops
without depending on npm or the external conformance package. The conformance job should supplement
those tests, not replace them.

## Implementation Plan

### Phase 1: Lean Beam MCP Server

Current first slice:

- single-root server model
- Lean tools only first
- broker-runtime-backed implementation
- `initialize`, `ping`, `tools/list`, `tools/call`, `shutdown`, and `exit`/initialized notification
  handling over newline-delimited stdio JSON-RPC
- MCP lifecycle gating for initialize / initialized notification before normal tool requests
- `2025-11-25` tool-call error split: malformed or unknown tools stay JSON-RPC errors, while
  invalid inputs for known tools return `isError=true` tool results
- generated MCP `inputSchema` payloads from the shared operation substrate
- normalized outputs
- end-to-end stdio coverage that starts Lean through `lean-beam-mcp`
- restart/stress coverage for real Lean-backed stdio tool calls

This validates the public MCP shape before generalizing.

Still missing from phase 1:

- install/wrapper integration that supplies `--lean-cmd` and `--lean-plugin` automatically
- live MCP progress forwarding during long-running calls
- MCP cancellation notification handling
- official MCP conformance coverage through a Streamable HTTP bridge

### Phase 2: Extract Reusable Runtime

Once `lean-beam-mcp` is stable, split out:

- JSON-RPC/LSP runtime
- typed protocol registry
- projection config + transforms

### Phase 3: Generic LSP-to-MCP Framework

Only after phase 1 and 2 are proven:

- support other LSP-like backends
- support spec-driven schema loading
- support notification/progress mapping generically

## Non-Goals

- full automatic exposure of all LSP methods
- pretending editor APIs are already good agent APIs
- solving every LSP server’s document policy in v1
- building a generic framework before the `runAt` case is proven

## Recommendation

Build the projection framework around `runAt` first.

The right order is:

1. `lean-beam-mcp`
2. extract reusable runtime pieces
3. generalize into a configurable LSP-to-MCP projection system

This keeps the design honest and prevents overbuilding around hypothetical backends.
