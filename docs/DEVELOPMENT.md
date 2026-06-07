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

## Code Organization

- `RunAt`: Lean LSP server plugin providing the `$/lean/runAt` request for speculative execution at
  arbitrary document points.
- `Beam`: shared broker, CLI, and MCP layer over Lean LSP plus Beam-specific extensions.
- `skills`: installed Claude/Codex workflow guidance built around `lean-beam`.
- Rocq support: a narrow auxiliary goal-probe surface through the same `lean-beam` wrapper, useful
  when porting from Rocq to Lean.
- `tests`: scenario-DSL coverage for LSP-level behavior, concurrent stress coverage, broker and
  wrapper regression suites, and install/runtime validation.

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

## Daemon Runtime Safety

The Beam daemon embeds Lean and Lake as libraries. Daemon/importable broker code must treat
process-wide exits as fatal bugs, not as ordinary control flow.

Do not call Lean/Lake APIs from daemon paths when they may call `IO.Process.exit`, `IO.exit`, or an
equivalent process-wide exit. Known hazards include Lake `runBuild` with `noBuild := true`, which is
CLI-oriented and can exit with Lake's no-build status, and `Lake.loadWorkspace` with
`updateToolchain := true`, which can request a Lake restart by exiting the current process. In daemon
code, use exception-returning checks such as `Workspace.checkNoBuild` for preflight decisions, run
follow-up trace computation without `noBuild`, and set `updateToolchain := false` on broker-side
`LoadConfig` literals.

The cheap regression guard is [scripts/check-daemon-safety.sh](../scripts/check-daemon-safety.sh).
It is intentionally conservative and should be updated when a new daemon-safe wrapper around an
exit-capable Lean/Lake API is introduced.

## MCP Projection Changes

Current MCP architecture, runtime setup, protocol versioning, and conformance notes live in
[docs/MCP.md](MCP.md). Keep this section as the maintainer checklist for implementation changes.

MCP work should go through the shared Lean operation layer in
[Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) and the typed MCP projection boundary in
[Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean). The MCP server is another projection over
the Beam operation set, not a raw LSP proxy.

When adding an MCP-facing operation:

- add or reuse a `Beam.Lean.Operation` first
- add a `ToolName` only if it is meant to be a public agent tool
- keep raw LSP methods and params out of MCP input types
- keep the project root in server/session context, not in each MCP tool input
- map to broker operations through the shared operation helpers instead of constructing ad hoc JSON
- normalize MCP output field names in the projection, for example `next_handle` and `proof_state`
- do not expose expert/raw escape hatches such as `lean-request-at` as MCP tools
- add or update [RunAtTest/Broker/McpProjectionTest.lean](../RunAtTest/Broker/McpProjectionTest.lean)
  and [RunAtTest/Broker/McpProtocolTest.lean](../RunAtTest/Broker/McpProtocolTest.lean), then run
  `bash tests/test-broker-fast.sh`

Keep executable `main` declarations out of importable runtime modules. Otherwise test and adapter
modules that import a runtime accidentally inherit the wrong root-level `main`.

Treat `Beam.Mcp.protocolVersion`, the external conformance baseline, and the advertised tool schema
as protocol surface. Changing any of them requires the audit and conformance steps in
[docs/MCP.md](MCP.md#protocol-and-errors) and
[docs/MCP.md](MCP.md#testing-and-conformance).

## Broker Server Boundaries

Keep [Beam/Broker/Server.lean](../Beam/Broker/Server.lean) focused on session lifecycle, request
dispatch, cancellation, document sync, and save barriers. Pure metrics structures and JSON encoding
live in [Beam/Broker/Metrics.lean](../Beam/Broker/Metrics.lean), so adding counters or changing
stats payloads does not require mixing pure reporting code into the process/session runtime.

The broker is not a raw LSP proxy. Its narrow public job is still to expose small Beam requests, but
internally it coordinates several responsibilities around the LSP process:

- the CLI owns process identity: project-root detection, bundle selection, registry files,
  endpoint/root validation, startup/shutdown, wrapper leases, and control-directory locks
- the broker owns request identity: daemon root validation, backend session lifetime, request
  dispatch, cancellation, active-request bookkeeping, transport errors, and the LSP document mirror
- the LSP server and plugin own Lean/Rocq semantic facts: elaboration, diagnostics, progress,
  goals, runAt execution, direct imports, save readiness, and save artifact generation
- Lake owns build graph and trace semantics; broker code may preflight and translate Lake outcomes,
  but daemon paths must not enter Lake APIs that can terminate the process

The thick part of the broker is request orchestration. For `sync`, `runAt`, `goals`, `runWith`,
`release`, and `save`, the broker currently reads the source file, updates the LSP document mirror,
waits for the relevant diagnostics/progress barrier when needed, asks the backend for extra semantic
facts, and shapes the final Beam response. That is useful product behavior, but it is policy layered
over lower-level LSP/plugin facts. Treat broker-side semantic history such as module sync/save
history, stale direct-dependency hints, save readiness interpretation, and saved-olean bookkeeping as
explicit orchestration logic. When this grows, prefer moving richer structured facts into a
backend/plugin method over reconstructing more Lean meaning in the broker.

Do not remove broker-side ordered file snapshots when thinning orchestration. Beam requests are
path-based and may run concurrently, while LSP document updates are an ordered client stream. The LSP
server can validate ordering only after the broker sends `didOpen` / `didChange`; it cannot know that
one filesystem read is older than another. `FileSyncSnapshot` in
[Beam/Broker/Server.lean](../Beam/Broker/Server.lean) and `syncSnapshotSeq` in
[Beam/Broker/DocumentState.lean](../Beam/Broker/DocumentState.lean) protect that pre-LSP race:
request handlers reserve a sequence number under the broker mutex, read and hash the file outside the
mutex, then ignore a completed snapshot if a newer read has already been applied to the same document.
Legacy in-session syncs use sequence zero because they do not provide cross-request ordering.

A thinner future design should keep the snapshot ordering boundary, but may reduce broker policy by
asking the backend for more complete structured answers, for example "sync this exact text/version,
wait until it is usable, and return save/readiness facts" instead of having the broker infer readiness
from several notification channels and follow-up requests.

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

The generic lock/process helpers live in [Beam/Cli/Lock.lean](../Beam/Cli/Lock.lean). Reusable CLI
argument parsing lives in [Beam/Cli/Args.lean](../Beam/Cli/Args.lean). Project-root inference,
Lean toolchain lookup, and Rocq command discovery live in [Beam/Cli/Project.lean](../Beam/Cli/Project.lean).
Daemon registry management, daemon startup/reuse, endpoint selection, and wrapper leases live in
[Beam/Cli/DaemonManager.lean](../Beam/Cli/DaemonManager.lean). Broker request plumbing, progress
messages, cancellation-on-interrupt, and response failure notes live in
[Beam/Cli/Broker.lean](../Beam/Cli/Broker.lean). User-facing stdout/stderr formatting helpers live
in [Beam/Cli/Output.lean](../Beam/Cli/Output.lean). Doctor, supported-toolchain, install-manifest,
and MCP config reporting live in [Beam/Cli/Info.lean](../Beam/Cli/Info.lean). The command dispatch
table lives in [Beam/Cli/Commands.lean](../Beam/Cli/Commands.lean), and [Beam/Cli/Usage.lean](../Beam/Cli/Usage.lean)
owns the help text. Install and bundle layout metadata lives in
[Beam/Cli/InstallLayout.lean](../Beam/Cli/InstallLayout.lean). Runtime bundle cache roots, source
hashing, fallback bundle builds, versioned metadata payloads, metadata acceptance checks, and
daemon/client/plugin helper resolution live in [Beam/Cli/RuntimeBundle.lean](../Beam/Cli/RuntimeBundle.lean).
Keep [Beam/Cli.lean](../Beam/Cli.lean) as the executable entry point: parse top-level options,
resolve `BEAM_HOME`, and delegate to `runCommand`.

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

CI uses Node 24-compatible first-party GitHub Actions majors for checkout, setup-node, and cache.
The MCP conformance job's `node-version` is the JavaScript test runtime and may stay pinned
separately from the action runtime.

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
