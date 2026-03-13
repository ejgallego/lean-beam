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
- `lean_sync`
- `lean_run_at_handle`
- `lean_run_with`
- `lean_run_with_linear`
- `lean_release`
- `lean_deps`
- `lean_save`
- `lean_close`

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

## Progress Model

Phase 1:

- return final `file_progress` in tool results

Phase 2:

- forward live progress as MCP progress/events during execution

The runtime should support both, but phase 1 is enough for a first useful server.

## Implementation Plan

### Phase 1: `runAt`-Specific MCP Server

Build a `runAt-mcp` executable with:

- single-root server model
- Lean tools only first
- wrapper/broker-backed implementation
- normalized outputs

This validates the public MCP shape before generalizing.

### Phase 2: Extract Reusable Runtime

Once `runAt-mcp` is stable, split out:

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

1. `runAt-mcp`
2. extract reusable runtime pieces
3. generalize into a configurable LSP-to-MCP projection system

This keeps the design honest and prevents overbuilding around hypothetical backends.
