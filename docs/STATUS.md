# Status

Lean Beam is alpha code and still mostly a personal experiment. The repository is public for
collaboration and reuse, but it is not yet a polished or stable general-purpose product.

The main product idea is a small, type-safe, isolated execution surface for Lean. Beam is the shared
thin layer on top of Lean LSP plus Beam-specific extensions: the Lean plugin provides the low-level
facts, and the local Beam layer turns those facts into practical CLI, broker, MCP, and skill
workflows.

## Current Scope

### Core Lean Surface

- standalone Lean plugin for `$/lean/runAt`
- internal proof-first, command-fallback basis selection
- typed response payload with messages, traces, optional proof state, and optional follow-up handle
- optional follow-up execution through `$/lean/runWith` and `$/lean/releaseHandle`
- explicit Lean `lean-beam sync` barrier with diagnostics wait and compact `fileProgress` reporting
- zero-build `lean-beam save` checkpoint for one synced workspace module

### Local Beam Layer

- local Beam daemon/client pair for Lean and Rocq workflows
- alpha Lean wrapper commands for follow-up handle continuation and release
- installed `lean-beam-search` helper for shorter shell branching/playout workflows
- explicit broker `ok` / `error` response envelopes for machine-readable local protocol consumers,
  while still accepting older inferred-`ok` envelopes on input
- `lean-beam open-files` daemon introspection for tracked documents, including saved/not-saved state,
  direct Lean deps when available, save preflight fields, checkpoint status, and the last compact
  `fileProgress`
- compact `fileProgress` reporting on slow Lean wrapper calls when matching LSP progress
  notifications were observed while the request was pending

### MCP And Agent Integration

- installed experimental `lean-beam-mcp` stdio server exposing the curated Lean Beam tool set through
  MCP `initialize`, `tools/list`, and `tools/call`
- MCP implementation backed directly by the broker runtime rather than by a second daemon/client
  connection
- `lean-beam-mcp --self-check <lean-file>` setup verification for the installed MCP path, root
  discovery through `roots/list`, and a real `lean_sync` tool call
- bundled Lean and Rocq skills for Codex/Claude workflow guidance

### Coverage

- repo-local regression coverage around isolation, stale state, cancellation, and handle invalidation
- broker, wrapper, install, MCP, and CI coverage described in [docs/TESTING.md](TESTING.md)

## API Notes

### Base Request

The base request is intentionally small:

- one document
- one position
- one Lean text payload
- no required command/tactic mode flag

Request-level failures stay at the transport layer. Semantic Lean outcomes stay in the normal typed
response payload.

### Follow-Up Handles

Follow-up handles exist, but they should be treated as alpha support APIs rather than as a frozen
long-term contract. Current handle behavior is:

- opaque
- document-bound
- invalidated by same-document edits
- invalidated by document close
- invalidated by worker restart or Beam daemon restart
- exact continuation requires an explicit handle path; separate `lean-beam run-at` calls do not chain
  through hidden state

### Sync And Save

`lean-beam sync`, `lean-beam save`, and `lean-beam close-save` should be read as a progression:

- `lean-beam sync` establishes the synced diagnostics-complete saved file snapshot
- `lean-beam save` checkpoints that snapshot for one module
- `lean-beam close-save` does the same checkpoint and then closes the tracked file

By default, `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` stream only errors for the
current request; `+full` widens that stream to warnings, info, and hints. The final JSON reports
compact summary fields rather than replaying the full LSP notification stream.

If Lean cannot reach a completed diagnostics barrier for the synced version, for example because an
imported target is stale and rebuild failure kills the worker session, `lean-beam sync` fails rather
than reporting partial success. `lean-beam save` and `lean-beam close-save` refuse to proceed past
that incomplete barrier.

Lean sync failures may attach a cheap direct-import recovery hint in `error.data`, including
`staleDirectDeps`, `saveDeps`, and `recoveryPlan`. This suggests `save` / `refresh` / `lake build`
next steps without running a full workspace dependency scan.

`lean-beam save` is module-oriented, not file-oriented. `lean-beam sync` can operate on an arbitrary
file the daemon can open, but `lean-beam save` requires a file that Lake resolves to a module in the
current workspace package graph. Standalone `.lean` files outside that graph are not valid save
targets.

If a speculative probe looks right and should become real source, the current contract is still:
make the real edit in the file, save it, then run `lean-beam sync`. The intended future direction is
to make that handoff cheap by reusing speculative execution rather than replaying it from scratch.

### Local Protocol

For programmatic local consumers, the preferred machine-readable surface is the JSON stream exposed
by `beam-client request-stream`; wrapper stderr should be treated as human-facing. Broker responses
include an explicit top-level `ok` boolean. Older response envelopes that omit `ok` still decode by
inferring success from the absence of `error`, but new producer code should emit `ok` because it gives
future projection layers an unambiguous success/error discriminator.

### MCP

`lean-beam-mcp` is an experimental stdio entry point. The installed wrapper is the preferred setup
path because it passes the matching `beam-cli` resolver automatically. Direct developer runs of
`.lake/build/bin/lean-beam-mcp` can still pass `--lean-cmd` and `--lean-plugin` explicitly.

Current MCP implementation, protocol, and conformance notes live in [docs/MCP.md](MCP.md).

## Known Limitations

### Toolchains And Bundles

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading is toolchain-keyed, not toolchain-agnostic.
- Supported Lean toolchains are listed in
  [supported-lean-toolchains](../supported-lean-toolchains).
- The supported fast path is the Lean toolchain pinned by this repository's `lean-toolchain`, because
  the plugin uses internal Lean APIs.
- The install script prebuilds an installed-skill bundle cache for that pinned toolchain by default.
- The install script also accepts `--toolchain <toolchain>` for explicit supported bundles and
  `--all-supported` for the full validated allowlist.
- Runtime requests first try that installed-skill bundle cache, then fall back to a project-local
  runtime bundle under `.beam/bundles/` for supported toolchains.
- Unsupported Lean toolchains fail early instead of attempting an opportunistic build.
- `lean-beam supported-toolchains` lists the validated toolchains, and `lean-beam doctor` reports
  support state, bundle source, and bundle key inputs.
- Bundle rebuild keys intentionally exclude the full `.lake/packages` checkout tree and instead use
  the runtime source tree plus `lean-toolchain`, `lake-manifest.json`, and
  `supported-lean-toolchains`.
- The first use of a supported but not-yet-prebuilt toolchain must still build a matching local
  fallback bundle.
- On a cold machine, that local fallback build may need network access to fetch dependencies.

### Runtime And Sandbox Behavior

- In sandboxed agent environments, Beam daemon startup itself may require elevated permissions even
  when the installed bundle and project-local `.beam` paths resolve correctly.
- A startup failure that reports `operation not permitted` through `.beam/beam-daemon-startup.log` is
  usually an environment restriction, not a bundle-resolution mismatch.
- Cancellation is cooperative; prompt stopping depends on inner elaboration polling interruption.
- The Beam daemon is single-root and keeps a conservative single active session per backend.

### MCP

- `lean-beam-mcp` currently advertises MCP protocol revision `2025-11-25` only. Older revisions are
  not advertised or tested.
- `lean-beam-mcp` follows the `2025-11-25` tool-call error split: malformed or unknown tools are
  JSON-RPC protocol errors, while invalid inputs for known tools return MCP tool execution errors
  with `isError=true`.
- `lean-beam-mcp` currently returns final tool results only; live MCP progress forwarding and MCP
  cancellation notifications are still future work.
- The Streamable HTTP bridge is test-only; the product entry point remains stdio.

### Sync, Save, And Staleness

- Zero-build `lean-beam save` helps checkpoint one module, but it is not a whole-workspace freshness
  solution.
- If you edit a dependency of the target file, downstream speculative results should be treated as
  stale until rebuild or checkpoint.
- Lean does not yet expose a better plugin-facing restart-required / stale-dependency hook here, so
  this limitation is currently explicit and user-visible.

### Distribution And Rocq

- Agent-skill distribution currently relies on a local checkout and local install script; it is not
  yet published through a registry or marketplace flow.
- Rocq support is currently limited to goal inspection through `coq-lsp`; it is not yet a full
  stateful execution layer.

## Direction

Near-term work is mostly about hardening and simplifying:

- keep the base `runAt` request small
- preserve strict per-request isolation
- reduce packaging and workspace rough edges
- publish a smoother distribution path, likely GitHub-backed install for Codex and plugin
  marketplace packaging for Claude
- improve stale-dependency handling
- replace broker-side diagnostics/fileProgress barrier inference with a stronger backend-facing
  readiness primitive
- keep Beam-daemon-side conveniences useful without turning them into a large public surface too
  early
- add a short comparison against Pantograph in the docs, to clarify where `runAt` fits among nearby
  Lean tooling

## Near-Term Work

Current release priorities:

1. Keep public docs release-ready as setup, CLI, and MCP behavior changes.
2. Polish AI/human harness workflows without turning them into public product surface.
3. Prefer stability fixes over new surface area unless they materially improve release confidence.

Tracked follow-ups:

- keep README short and human-facing; move detailed setup, maintainer workflow, and agent guidance
  to setup, contributor, development, and skill docs
- decide whether a short architecture note belongs in README, or whether this status doc plus
  [docs/DEVELOPMENT.md](DEVELOPMENT.md) are enough
- tighten the AI-first harness story so preferred maintainer entrypoints are obvious for both humans
  and AI agents
- surface `syncBarrierIncomplete` recovery hints more clearly in the human-facing CLI path, not just
  in `error.data`
- investigate and fix the intermittent `handleProofBranchDsl` CI failure if it reappears
- continue validating every supported Lean toolchain in CI before expanding the allowlist further
- replace the broker's remaining stopgap dependency and readiness logic with stronger Lake or
  backend-facing primitives when Lean exposes them
