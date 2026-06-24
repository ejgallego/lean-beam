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
By default, the harness uses `.codex-worktrees/lean-beam` inside the repo rather than `/tmp` or a
home-global worktree root.

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

MCP work should go through the shared Lean operation layer in
[Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) and the typed MCP projection boundary in
[Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean). CLI Lean commands should go through the
CLI projection helpers in [Beam/Cli/LeanOperation.lean](../Beam/Cli/LeanOperation.lean) instead of
constructing broker requests directly in the command dispatcher.
`Beam/Lean/Operation.lean` names curated Lean operations, maps typed inputs to broker requests, and
owns the tool input schemas. `Beam/Mcp/Projection.lean` names the public MCP tools and normalizes
selected broker results. Workspace/session setup is a shared Beam surface in
[Beam/Workspace.lean](../Beam/Workspace.lean); MCP tools such as `lean_init_workspace` should
project that contract instead of inventing MCP-only root policy or pretending setup is a raw Lean
operation. Lean/Lake root recognition belongs in
[Beam/Lean/Workspace.lean](../Beam/Lean/Workspace.lean), not in the generic workspace state
machine.

The executable MCP path is split into importable runtime modules and tiny entry-point modules:

- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean): MCP JSON-RPC and tool-result helpers
- [Beam/Mcp/Options.lean](../Beam/Mcp/Options.lean): executable option parsing and usage text
- [Beam/Mcp/Roots.lean](../Beam/Mcp/Roots.lean): MCP `roots/list` negotiation and root selection
- [Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean): project-root to broker-runtime setup
- [Beam/Mcp/SelfCheck.lean](../Beam/Mcp/SelfCheck.lean): installed-wrapper self-check driver
- [Beam/Mcp/Server.lean](../Beam/Mcp/Server.lean): broker-backed stdio MCP server logic
- [Beam/Workspace.lean](../Beam/Workspace.lean): shared workspace init input, result shape,
  active-root metadata, and session binding policy
- [Beam/Lean/Workspace.lean](../Beam/Lean/Workspace.lean): Lean/Lake project-root validation for
  CLI and MCP setup paths
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

When adding an MCP-facing operation, use this order:

1. Add or reuse a `Beam.Lean.Operation`. Define the typed input, broker-request adapter, description,
   and closed input schema there. Use [Beam/JsonSchema.lean](../Beam/JsonSchema.lean) for public
   tool schemas instead of hand-rolling schema JSON.
2. If the operation should be a public MCP tool, make sure `Beam.Mcp.Projection` projects it from
   the shared Lean operation surface. Normal Lean MCP tool names derive from the operation key with
   the `lean_` prefix; `lean_init_workspace` is the MCP-only setup exception. Do not add raw LSP
   method names or expert/raw escape hatches such as `lean-request-at`.
3. If the operation also belongs on the CLI, add or update the request helper in
   [Beam/Cli/LeanOperation.lean](../Beam/Cli/LeanOperation.lean). Keep CLI compatibility behavior,
   such as omitted-text validation, at the CLI projection boundary.
4. Keep project-root selection in server/session setup, not in each Lean operation input. Root
   negotiation belongs to `lean_init_workspace`, explicit `--root`, or exactly one MCP `roots/list`
   result. `lean_init_workspace` is the only setup tool that accepts a root, and it should keep
   projecting the shared `Beam.Workspace` contract: explicit, absolute, idempotent for `set` and
   `verify`, and destructive only through `mode=reset`, which discards the current runtime and
   invalidates handles before switching roots. Keep reset result fields in snake_case, including
   `runtime_reused`, `previous_root`, and `invalidated_handles`.
5. Normalize MCP output field names in the projection, for example `next_handle` and `proof_state`.
   Transport/setup failures should become structured tool or JSON-RPC errors; semantic Lean failures
   should remain normal tool results when the broker reports them that way.
6. Keep progress and readiness separate. Lean `fileProgress` is useful observability and a
   sync/save barrier input, but it is not a general proof that every operation is semantically ready.
   Setup latency should be attributed to setup phases such as `lean_init_workspace`, not reported as
   a later Lean operation timeout.
7. Add or update [RunAtTest/Broker/McpProjectionTest.lean](../RunAtTest/Broker/McpProjectionTest.lean)
   for operation-to-broker mapping and result normalization, then update
   [RunAtTest/Broker/McpProtocolTest.lean](../RunAtTest/Broker/McpProtocolTest.lean) for generated
   tool schema, lifecycle, root setup, and protocol error-shape expectations.
8. Run `lake build beam-mcp-projection-test beam-mcp-protocol-test beam-cli lean-beam-mcp`, the two
   focused MCP test executables, `git diff --check`, and `bash tests/test-beam-fast.sh`.

For setup tools that do not map to Lean execution, keep the public tool projection in `Beam.Mcp`,
put shared workspace/session policy in `Beam.Workspace`, and make the non-broker boundary explicit
in tests.

Lean/Lake root validation should stay shared between CLI and MCP. `lean_init_workspace` should keep
using `Beam.Lean.Workspace.resolveRoot`, which requires an absolute root because it is a client API.
Local startup paths such as `beam --root` and `lean-beam-mcp --root` should use
`Beam.Lean.Workspace.resolveCliRoot`, which first resolves relative paths from the current working
directory and then applies the same Lean/Lake project validation before `Beam.Workspace` session
policy.

When a public CLI command exposes the same Lean operation, add or update its request helper in
`Beam.Cli.LeanOperation` and keep request-shape parity coverage in
[RunAtTest/Broker/CliDaemonTest.lean](../RunAtTest/Broker/CliDaemonTest.lean). CLI-only compatibility
behavior, such as preserving broker-side validation for omitted text arguments, should stay at this
projection boundary and should not leak into the typed MCP inputs.

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
history, stale direct-dependency hints, and saved-olean bookkeeping as
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
wait until it is usable, and return readiness facts" instead of having the broker infer state from
several notification channels and follow-up requests. The current save path already uses this split
for the checkpoint decision: the broker reads and hashes the file, applies the matching LSP document
version, and passes both expected values to the Lean-side save-readiness and save-artifact requests;
Lean is authoritative for `saveReady`, while streamed diagnostics and broker summaries are evidence
attached to that verdict.

Until richer backend-facing readiness primitives exist, keep readiness claims deliberately narrow:
`fileProgress` is an observable LSP progress signal, and it is a barrier input only for the
operations that define a diagnostics/save barrier (`sync`, `save`, and `close-save`). Tests that need
to prove request overlap, cancellation, startup, or stale-state transitions should wait on explicit
state such as request IDs, response files, registry files, or fixture sentinels instead of treating
progress as a general semantic-ready signal.

Broker-side readiness projection and sync/save response shaping live in
[Beam/Broker/Readiness.lean](../Beam/Broker/Readiness.lean). Keep LSP/session IO in
`Beam/Broker/Server.lean`, but put barrier interpretation, top-level `fileProgress` attachment,
fallback evidence attachment, and sync/save success or `syncBarrierIncomplete` response construction
behind that named boundary.

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

The generic lock/process helpers live in [Beam/Cli/Lock.lean](../Beam/Cli/Lock.lean). Project
daemon control locks use a bounded wait so a live but stuck wrapper process produces owner
diagnostics instead of making later clients wait silently; `BEAM_CONTROL_LOCK_TIMEOUT_MS` can shorten
or lengthen that wait for local debugging. Bundle build locks intentionally keep the lower-level
unbounded helper because another process may legitimately be compiling a helper bundle. Reusable CLI
argument parsing lives in [Beam/Cli/Args.lean](../Beam/Cli/Args.lean). Project-root inference,
Lean toolchain lookup, and Rocq command discovery live in [Beam/Cli/Project.lean](../Beam/Cli/Project.lean).
Shared filesystem path helpers live in [Beam/Path.lean](../Beam/Path.lean). Use them instead of
copying string-prefix checks or raw `IO.FS.realPath` wrappers:

- `resolveExistingPath` resolves an existing path to its canonical spelling.
- `resolvePathAgainstRoot` resolves an absolute path as-is or a relative path under an already
  resolved root.
- `sameFilePath` compares existing paths through canonical spelling and falls back to exact text
  equality for missing paths.
- `pathRelativeToRoot?` and `pathRelativeToRootOrSelf` derive workspace-relative display/cache paths
  with a real directory-boundary check, so `/tmp/foo` does not accidentally match `/tmp/foobar`.

Keep raw path strings only for JSON payloads, diagnostics, and intentionally stable cache keys.
When symlink or platform-alias behavior matters, resolve paths before deriving workspace-relative
strings.

Direct `IO.asTask`, `BaseIO.asTask`, and `EIO.asTask` calls should make their priority explicit.
Use `Task.Priority.dedicated` for blocking or long-lived IO such as process pipe readers, accepted
client handlers, signal watchers, and streaming callback loops. Lean's regular task pool is bounded
and shared with Lake/elaboration work, so a tiny task that blocks in an OS read can still starve
normal-priority work on low-core runners. The cheap regression guard is
[scripts/check-task-priority.sh](../scripts/check-task-priority.sh).

Daemon registry management, daemon startup/reuse, endpoint selection, and wrapper leases live in
[Beam/Cli/DaemonManager.lean](../Beam/Cli/DaemonManager.lean). Broker request plumbing, progress
messages, cancellation-on-interrupt, and response failure notes live in
[Beam/Cli/Broker.lean](../Beam/Cli/Broker.lean). User-facing stdout/stderr formatting helpers live
in [Beam/Cli/Output.lean](../Beam/Cli/Output.lean). Doctor, supported-toolchain, install-manifest,
and MCP config reporting live in [Beam/Cli/Info.lean](../Beam/Cli/Info.lean). The command dispatch
table lives in [Beam/Cli/Commands.lean](../Beam/Cli/Commands.lean), and [Beam/Cli/Usage.lean](../Beam/Cli/Usage.lean)
owns the help text. Lean command to broker-request projection lives in
[Beam/Cli/LeanOperation.lean](../Beam/Cli/LeanOperation.lean). Install and bundle layout metadata lives in
[Beam/Cli/InstallLayout.lean](../Beam/Cli/InstallLayout.lean). Runtime bundle compatibility imports
live in [Beam/Cli/RuntimeBundle.lean](../Beam/Cli/RuntimeBundle.lean); implementation details are
split under [Beam/Cli/RuntimeBundle](../Beam/Cli/RuntimeBundle). Keep source hashing, resolved
toolchain fingerprinting, metadata acceptance, and fallback bundle builds in their focused
submodules instead of growing the umbrella import. Bundle IDs and metadata must include both the
Beam runtime source hash and the resolved Lean/Lake fingerprint so local custom toolchain relinks
and reported identity changes cannot silently reuse stale helpers. The user-facing model is in
[CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md).
Keep [Beam/Cli.lean](../Beam/Cli.lean) as the executable entry point: parse top-level options,
resolve `BEAM_HOME`, and delegate to `runCommand`.

What this does not promise:

- it does not promise the daemon will still be alive after all sandboxed wrapper calls have exited
- the guarantee is narrower: overlapping wrapper requests on the same root should survive correctly

## Recommended Test Order

- LSP request / handle / scenario changes: `bash tests/test-lsp.sh`
- Beam broker protocol / stream / barrier changes: `bash tests/test-beam-fast.sh`
- Beam wrapper / save replay / bundle-resolution changes: `bash tests/test-beam-slow.sh`
- Beam install / runtime layout changes: `bash tests/test-beam-install.sh`
- supported Lean toolchain changes: `bash tests/test-beam-toolchain-compat.sh <toolchain>`
- Rocq broker / wrapper changes: `bash tests/test-beam-rocq.sh`
- maintainer harness / validation wrapper changes: `bash tests/test-maintainer.sh`
- risky local install or wrapper validation: `bash scripts/validate-defensive.sh`
- shell changes: `bash scripts/lint-shell.sh`

Use `bash tests/test-beam.sh` when you want the aggregate default Beam signal.

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

## Lean 4.30 And 4.31 Compatibility Shims

Current validated support spans Lean `v4.29.0` through `v4.31.0`, which requires local
compatibility code. When the support window no longer crosses these API boundaries, re-check and
likely simplify these spots:

- `RunAt/Requests/Save.lean`: `emitCForSavedModule` selects between the older `Lean.IR.emitC` API and
  the newer `Lean.Compiler.LCNF.emitC` API.
- `RunAt/Requests/DiagnosticsCompat.lean`: `collectCurrentDiagnosticsCompat` selects between the
  older `EditableDocument.diagnosticsRef` API and the newer
  `EditableDocumentCore.collectCurrentDiagnostics` API.
- `Beam/Broker/Transport.lean`: the transport uses `Std.Internal.UV.TCP` directly because the async
  TCP wrapper moved from `Std.Internal.Async.TCP` to `Std.Async.TCP`.
- `Beam/Broker/LakeSave.lean`: `mkModuleOutputDescrsCompat` selects between the older
  `ModuleOutputDescrs` record shape and the newer shape with `isModule`.

## Process

For commit, PR, and author identity guidance, see [CONTRIBUTING.md](../CONTRIBUTING.md).
