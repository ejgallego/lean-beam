# Development

This repository is AI-first in practice, but the local workflow should work for both humans and AI
agents.

The public product surface is `lean-beam`. The local development harness is for maintainers and
contributors.

## Current Priorities

Current maintainer priorities are:

- keep README human-facing and release-ready
- keep maintainer and agent workflow guidance out of README
- make the harness work well for both humans and AI agents without turning it into public product
  surface
- prefer small targeted fixes over broad refactors unless a release-facing doc or workflow problem
  demands the larger change

## Entry Points

- human user of the project: [README.md](../README.md)
- human contributor: [CONTRIBUTING.md](../CONTRIBUTING.md)
- maintainer using local harness workflows: this document
- AI agent working inside the repo: [AGENTS.md](../AGENTS.md) plus the relevant installed skill doc

If the question is "how do I use the product?", do not start here.
If the question is "how do I work on the repo safely and efficiently?", start here.

## Local Workflow

Start from the repo root and prefer dedicated worktrees for new tasks:

```bash
./scripts/codex-harness.sh session start <task-id>
```

That keeps new work off the primary checkout and matches the repository's default Codex workflow.
By default, the harness uses `~/.codex/worktrees/lean-beam` rather than `/tmp` so task
worktrees survive reboots.

Important local scripts:

- `scripts/codex-harness.sh`: start and manage dedicated task worktrees
- `scripts/codex-session-start.sh`: lower-level helper used by the harness
- `scripts/validate-defensive.sh`: slower guarded validation in a cloned `/tmp` sandbox
- `scripts/lean-beam`: public wrapper surface

Preferred maintainer entrypoints:

- new Codex task: `./scripts/codex-harness.sh session start <task-id>`
- risky wrapper/install validation: `bash scripts/validate-defensive.sh`
- public workflow checks: `lean-beam` and the skill docs
- sandboxed repeated wrapper probes: `lean-beam ensure --hold`, then interrupt that foreground
  process when the probe loop is finished
- contributor process questions: [CONTRIBUTING.md](../CONTRIBUTING.md)

## Human And AI Roles

- README is for humans who want to understand and use the project
- skills document the installed workflow surface that agents should follow
- `AGENTS.md` carries repo-specific agent instructions
- this document is for maintainers working locally, whether the operator is a human or an AI
- the Codex harness scripts are maintainer tools, not public product surface

## Change Discipline

- prefer the wrapper or broker client over raw LSP when the task fits
- if a subtle behavior changes, add or update a regression test first
- keep destructive cleanup scoped to owned temp or worktree paths
- if Lean reports stale or rebuild trouble unexpectedly, stop and surface it explicitly

## MCP Projection Changes

MCP work should go through the shared Lean operation layer in
[Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) and the typed MCP projection boundary in
[Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean).
`Beam/Lean/Operation.lean` names curated Lean operations, maps typed inputs to broker requests, and
owns the tool input schemas. `Beam/Mcp/Projection.lean` names the public MCP tools and normalizes
selected broker results.

The executable MCP path is split into importable runtime modules and tiny entry-point modules:

- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean): MCP JSON-RPC and tool-result helpers
- [Beam/Mcp/Roots.lean](../Beam/Mcp/Roots.lean): MCP `roots/list` negotiation and root selection
- [Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean): project-root to broker-runtime setup
- [Beam/Mcp/SelfCheck.lean](../Beam/Mcp/SelfCheck.lean): installed-wrapper self-check driver
- [Beam/Mcp/Server.lean](../Beam/Mcp/Server.lean): broker-backed stdio MCP server logic
- [Beam/Mcp/ServerMain.lean](../Beam/Mcp/ServerMain.lean): `lean-beam-mcp` executable entry point
- [Beam/Broker/ServerMain.lean](../Beam/Broker/ServerMain.lean): `beam-daemon` executable entry point

Keep executable `main` declarations out of importable runtime modules. Otherwise test and adapter
modules that import a runtime accidentally inherit the wrong root-level `main`.

The installed `bin/lean-beam-mcp` wrapper is the public setup path. It pairs the MCP executable with
the same installed `beam-cli` and passes `--beam-cli`; `Beam/Mcp/Runtime.lean` then asks
`beam-cli --root <root> mcp-config` for the project-specific Lean command and runAt plugin after
root selection. Keep this resolver as a narrow CLI/MCP setup boundary. Do not duplicate bundle
selection logic in the MCP server, and do not make MCP clients pass raw plugin paths in normal
installed use.

When adding an MCP-facing operation:

- add or reuse a `Beam.Lean.Operation` first
- add a `ToolName` only if it is meant to be a public agent tool
- keep raw LSP methods and params out of the MCP input types
- keep the project root in server/session context, not in each MCP tool input; root negotiation
  belongs in `Beam/Mcp/Roots.lean`, either through the explicit `--root` override or exactly one
  MCP `roots/list` result
- map to broker operations through the shared operation helpers instead of constructing ad hoc JSON
- normalize MCP output field names in the projection, for example `next_handle` and `proof_state`
- do not expose expert/raw escape hatches such as `lean-request-at` as MCP tools
- add or update [RunAtTest/Broker/McpProjectionTest.lean](../RunAtTest/Broker/McpProjectionTest.lean)
  and [RunAtTest/Broker/McpProtocolTest.lean](../RunAtTest/Broker/McpProtocolTest.lean), then run
  `bash tests/test-broker-fast.sh`

`Beam.Mcp.protocolVersion` is the only MCP revision advertised during initialization. Bump it, or
add support for another revision, only with a protocol audit: check the upstream MCP
schema/changelog, update local protocol tests, run the Lean-backed stdio harness, update
[docs/STATUS.md](STATUS.md), and run [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh)
against the revised conformance baseline.

The local Streamable HTTP bridge under [tests/mcp_http_bridge.py](../tests/mcp_http_bridge.py) is a
test/conformance adapter over the stdio executable, not a separate product transport. Keep it thin:
it should translate HTTP status/header rules to the stdio server without adding a second MCP tool
implementation.

The default conformance gate uses the pinned `@modelcontextprotocol/conformance@0.1.16` package and
the explicit scenario set in [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh).
Changing the package version or scenario baseline is a protocol change: update
[docs/TESTING.md](TESTING.md), run the local conformance script, and check the workflow with
`actionlint`.

## Sandboxed Wrapper Path

This wrapper path is easy to break accidentally, so keep the mental model simple.

What was broken:

- Codex-style wrapper calls run in separate PID-isolated sandboxes.
- A later wrapper call could look at the daemon pid in the registry and think the daemon was dead,
  even when the daemon was still alive and answering on its TCP endpoint.
- If one wrapper call started the daemon and then exited while sibling wrapper calls were still
  using it, that exit could tear the daemon down mid-flight.

What the fix does:

- if the registry endpoint still answers, treat the daemon as live even if the recorded pid looks
  wrong in the current sandbox
- if a wrapper call started the daemon, keep that wrapper call alive until overlapping sibling
  wrapper calls for the same project root drain
- `lean-beam ensure --hold` gives agents an explicit foreground owner when they need daemon reuse
  across separate PID-isolated shell invocations
- wrapper leases include PID namespace metadata, so same-namespace stale leases left by killed
  wrappers are pruned without treating different sandbox namespaces as safe to probe by pid
- the regression for this path is
  [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh)

The generic lock/process helpers live in [Beam/Cli/Lock.lean](../Beam/Cli/Lock.lean). Keep wrapper
and daemon lifecycle code in `Beam/Cli.lean`, but put reusable lock behavior there so it can stay
unit-tested without importing the full CLI command surface. Install and bundle layout metadata lives
in [Beam/Cli/InstallLayout.lean](../Beam/Cli/InstallLayout.lean); heavier bundle cache/build
resolution still belongs to `Beam/Cli.lean` until it has a stable typed boundary worth extracting.

What this does not promise:

- it does not promise the daemon will still be alive after all sandboxed wrapper calls have exited
- the guarantee is narrower: overlapping wrapper requests on the same root should survive correctly

## Recommended Test Order

- broker protocol / stream / barrier changes: `bash tests/test-broker-fast.sh`
- wrapper / install / bundle-resolution changes: `bash tests/test-broker-slow.sh`
- Rocq broker / wrapper changes: `bash tests/test-broker-rocq.sh`
- risky local install or wrapper validation: `bash scripts/validate-defensive.sh`
- shell changes: `bash scripts/lint-shell.sh`

Use `bash tests/test-broker.sh` when you want the aggregate broker signal.

## Lean 4.28 Compatibility Shims

Current validated support includes Lean `v4.28.0`, which requires two local compatibility shims.
When support for `v4.28.0` is eventually dropped, re-check and likely simplify these spots:

- `RunAt/Protocol.lean`, `RunAt/Internal/SaveSupport.lean`, and `RunAt/Internal/DirectImports.lean`:
  `FileSource` instances route through `Lean.Lsp.fileSource p.textDocument` so the same code works
  across the older `FileIdent` return type in `v4.28.0` and the newer `DocumentUri` API.
- `Beam/Broker/LakeSave.lean`: `hashOfHashable` / `addHashablePureTrace` exist because Lake
  `v4.28.0` lacks the newer generic `ComputeHash [Hashable α]` instance that makes plain
  `addPureTrace mod.name` and `addPureTrace mod.pkg.id?` work upstream in newer Lean versions.

## Lean 4.30 Compatibility Shims

Current validated support spans Lean `v4.29.0` and `v4.30.0`, which requires two local
compatibility shims. When the support window no longer crosses this API boundary, re-check and
likely simplify these spots:

- `RunAt/Requests/Save.lean`: `emitCForSavedModule` selects between the older `Lean.IR.emitC` API and
  the newer `Lean.Compiler.LCNF.emitC` API.
- `Beam/Broker/LakeSave.lean`: `mkModuleOutputDescrsCompat` selects between the older
  `ModuleOutputDescrs` record shape and the newer shape with `isModule`.

## Process

For commit, PR, and author identity guidance, see [CONTRIBUTING.md](../CONTRIBUTING.md).
