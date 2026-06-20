# Testing

The current test story is good for an alpha repository, but it is recent and mostly end-to-end.

Most of the harness was built over March 10-11, 2026. Coverage is strongest around externally
visible behavior: request semantics, stale-state handling, cancellation, handle invalidation, and
Beam daemon integration.

## Coverage Map

| Area | Primary checks | What they protect |
| --- | --- | --- |
| runAt semantics | [tests/test.sh](../tests/test.sh), [tests/scenario](../tests/scenario), [RunAtTest/Scenario.lean](../RunAtTest/Scenario.lean) | position selection, async edits, multi-document behavior, and externally visible request results |
| follow-up handles | [tests/scenario/handleDsl.scn](../tests/scenario/handleDsl.scn), [RunAtTest/Handle](../RunAtTest/Handle), [RunAtTest/Scenario/MctsProofSearchTest.lean](../RunAtTest/Scenario/MctsProofSearchTest.lean) | handle minting, continuation, linear consumption, release, cancellation, invalidation, and search-style branching |
| broker protocol | [RunAtTest/Broker/ProtocolTest.lean](../RunAtTest/Broker/ProtocolTest.lean), [RunAtTest/Broker/RequestStreamContractTest.lean](../RunAtTest/Broker/RequestStreamContractTest.lean), [tests/test-broker-fast.sh](../tests/test-broker-fast.sh) | response envelopes, stream contracts, progress semantics, startup smoke, and barrier failure shape |
| CLI daemon and bundles | [RunAtTest/Broker/CliDaemonTest.lean](../RunAtTest/Broker/CliDaemonTest.lean), [tests/test-install.sh](../tests/test-install.sh), [tests/test-toolchain-compat.sh](../tests/test-toolchain-compat.sh) | lock lifecycle, deterministic helper identity, bundle metadata schema, source hashing, toolchain acceptance, and stale bundle rejection |
| wrapper workflows | [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh), [tests/test-beam-wrapper-daemon.sh](../tests/test-beam-wrapper-daemon.sh), [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh) | wrapper JSON, request cancellation, `sync`/`save`, daemon reuse, lease cleanup, port collision handling, and PID-isolated sandbox behavior |
| zero-build save | [tests/test-broker-save-olean.sh](../tests/test-broker-save-olean.sh), [RunAtTest/Broker/SaveStreamTest.lean](../RunAtTest/Broker/SaveStreamTest.lean) | exact-target replay, downstream importer reuse, cancellation, stale traces, and race behavior around saved `.olean` artifacts |
| MCP | [RunAtTest/Broker/McpProjectionTest.lean](../RunAtTest/Broker/McpProjectionTest.lean), [RunAtTest/Broker/McpProtocolTest.lean](../RunAtTest/Broker/McpProtocolTest.lean), [tests/test-mcp-stdio.py](../tests/test-mcp-stdio.py), [tests/test-mcp-http-bridge.py](../tests/test-mcp-http-bridge.py), external conformance in CI | tool schemas, lifecycle gating, root setup, raw LSP rejection, stdio behavior, Streamable HTTP bridge behavior, and protocol conformance |
| Rocq sidecar | [tests/test-broker-rocq.sh](../tests/test-broker-rocq.sh), [RunAtTest/Broker/RocqSmokeTest.lean](../RunAtTest/Broker/RocqSmokeTest.lean) | Rocq goal-probe setup, `coq-lsp` discovery, and keeping the Rocq path separate from Lean-specific workflow |
| repo maintenance | [scripts/lint-shell.sh](../scripts/lint-shell.sh), [scripts/check-markdown-links.sh](../scripts/check-markdown-links.sh), [tests/test-codex-harness.sh](../tests/test-codex-harness.sh) | shell portability, Bash `set -u` array safety, repository-local markdown links, and dedicated worktree discipline |

The optional [tests/test-stage0-toolchain.sh](../tests/test-stage0-toolchain.sh) smoke checks
`--custom-toolchain lean4-stage0` on machines where that elan toolchain exists. It is intentionally
local-only and skips elsewhere. See [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the custom
toolchain and runtime-bundle model that test exercises.

## Race-Test Discipline

Race and concurrency regressions should wait for observable state, not for guessed wall-clock
delays. Prefer request IDs plus cancellation acknowledgements, wrapper progress text, registry
files, non-empty response files, and Lean-side sentinel files that prove a slow command reached the
intended phase. Use [tests/lib/beam-wrapper-common.sh](../tests/lib/beam-wrapper-common.sh) helpers
for repeated shell polling patterns. Prefer its JSON assertion helpers for wrapper response checks
so failures print payloads and captured context consistently.

Keep `fileProgress` and readiness distinct in assertions. For `lean-beam sync`, `lean-beam save`,
and `lean-beam close-save`, completed progress is part of the diagnostics/save barrier contract.
For other wrapper requests, progress text is a useful synchronization marker only; it is not proof
that the file or request has reached a stronger semantic readiness state.

Fixed sleeps are acceptable only when the behavior under test is explicitly elapsed-time behavior,
such as "the daemon remains live after a short idle interval". When a test is trying to observe
startup, overlap, cancellation, or a stale-state transition, add a bounded polling helper or a
fixture sentinel instead.

## Search-Style Coverage

The repo now has a seeded MCTS-style proof-search regression in
[RunAtTest/Scenario/MctsProofSearchTest.lean](../RunAtTest/Scenario/MctsProofSearchTest.lean).

That test exercises:

- repeated playouts from one preserved proof handle
- non-linear branching from the same recovered basis
- linear continuation on derived handles
- semantic-failure probes that must not mutate preserved handles
- linear failure probes that must consume the current handle
- cancellation on branched proof-search handles, including preserved-parent reuse and linear-handle consumption
- explicit release of explored side branches
- stale invalidation of live search handles after a document edit
- nested semantic failures that preserve proof-state payloads, suppress successor handles, and still distinguish non-linear from linear handle reuse

This sits on top of earlier search-enabling coverage:

- non-linear proof branching in
  [tests/scenario/handleProofBranchDsl.scn](../tests/scenario/handleProofBranchDsl.scn)
- programmable request orchestration through [RunAtTest/Scenario.lean](../RunAtTest/Scenario.lean)
- shuffled concurrent workload coverage in
  [RunAtTest/Scenario/StressTest.lean](../RunAtTest/Scenario/StressTest.lean)
- nested multi-goal cursor corner cases in
  [tests/interactive/proofNestedConstructorOrder.lean](../tests/interactive/proofNestedConstructorOrder.lean),
  [tests/interactive/proofNestedBulletWhitespace.lean](../tests/interactive/proofNestedBulletWhitespace.lean), and
  [tests/interactive/proofNestedRightSibling.lean](../tests/interactive/proofNestedRightSibling.lean)
- nested right-sibling handle continuation in
  [tests/scenario/handleNestedRightBranchDsl.scn](../tests/scenario/handleNestedRightBranchDsl.scn)

What still does not exist:

- a benchmark-style test for much larger search trees
- a search test that models a full UCT scoring policy rather than seeded playout branching
- performance assertions around many thousands of successor handles

So the current state is: the repo now tests a real search-style handle workflow, but it is still a
correctness regression, not yet a performance benchmark.

## Broker Suites

- start with [tests/test-broker-fast.sh](../tests/test-broker-fast.sh) for broker-stream, barrier,
  request-stream contract, MCP projection-boundary changes, protocol-only MCP checks, and one
  Lean-backed MCP stdio pass; this is the quickest broker signal. It also runs
  [scripts/check-markdown-links.sh](../scripts/check-markdown-links.sh), so stale repository-local
  documentation links fail in CI.
- add [tests/test-broker-slow.sh](../tests/test-broker-slow.sh) when the change touches wrapper,
  install, bundle-resolution behavior, or MCP server reliability; it repeats the MCP stdio harness
  across several server restarts before running focused daemon lifecycle checks and the broader
  wrapper/install checks. Slow-suite steps are grouped and timed in CI through
  [tests/lib/ci-steps.sh](../tests/lib/ci-steps.sh). Multi-command functions passed to `run_step`
  must return failures explicitly, because the helper keeps control long enough to print timing and
  close GitHub log groups.
- use [tests/test-broker-rocq.sh](../tests/test-broker-rocq.sh) for Rocq broker and wrapper
  coverage, including `coq-lsp` discovery from project-local `_opam` roots and the active PATH
- use [tests/test-broker.sh](../tests/test-broker.sh) to execute both suites together before
  landing a broader broker-facing change
- use [scripts/lint-shell.sh](../scripts/lint-shell.sh) when you change shell wrappers, installer,
  or shell-based test harnesses; CI runs the same `shellcheck` pass
- use [tests/test-stage0-toolchain.sh](../tests/test-stage0-toolchain.sh) for a local smoke of
  `--custom-toolchain lean4-stage0`; it is intentionally optional and skips on machines without that
  linked elan toolchain. This is the closest local check for Lean-development custom toolchains:
  install should prebuild the custom bundle, `doctor` should resolve that installed bundle and report
  a toolchain fingerprint, and `ensure` should start from the installed helpers rather than building
  an unrelated fallback.

## MCP Coverage Plan

The MCP server currently advertises protocol revision `2025-11-25` only. Version support should stay
narrow; adding another revision means updating `Beam.Mcp.protocolVersion` / version negotiation
policy, auditing schema and error-mapping changes, updating docs, and running both the local MCP
harness and external conformance coverage.

Current MCP gates are layered:

- protocol unit tests for JSON-RPC shapes, tool schemas, shared workspace init policy, lifecycle
  gating, malformed-tool protocol errors, roots negotiation helpers, runtime setup errors, and
  known-tool input validation as tool execution errors
- projection tests for the shared Beam operation substrate and agent-facing field names
- `tests/test-mcp-stdio.py` for real stdio process behavior over a copied Lean project, including
  table-driven lifecycle/root setup cases, explicit `--root`, `lean_init_workspace`, recovery after
  missing-roots setup errors, relative `--root` startup, same-root and live-root reset with handle
  invalidation, stale-root reset recovery, and client-advertised MCP roots
- `tests/test-mcp-http-bridge.py` for local Streamable HTTP transport behavior over the same stdio
  server
- `tests/test-broker-fast.sh` for one quick Lean-backed MCP stdio path, one HTTP bridge smoke, and a
  cheap protocol-only smoke; it also runs the public `lean-beam-mcp --self-check` path against the
  fixture project, negative setup checks for missing roots/files and non-workspace CLI roots, and a
  forced timeout check that verifies self-check failures identify the stalled workspace setup phase
- `tests/test-broker-slow.sh` for repeated MCP server restarts and repeated real tool calls
- `tests/test-install.sh` for installed runtime layout and a real installed `lean-beam-mcp` wrapper
  tool call that resolves its Lean command and plugin through `beam-cli mcp-config`; it also checks
  the installed MCP self-check command
- the `mcp-conformance` CI job for official external protocol/lifecycle coverage over a local
  Streamable HTTP bridge on Ubuntu and macOS

[tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh) is the external conformance entry
point. It starts a fresh local HTTP bridge per scenario and runs selected server scenarios from the
pinned `@modelcontextprotocol/conformance@0.1.16` package. The default scenarios are
`server-initialize`, `ping`, and `tools-list`, and CI runs that default set on Ubuntu and macOS.
Each scenario is grouped and timed in CI. Keep the scenario list explicit with
`MCP_CONFORMANCE_SCENARIOS`; if a broader local run needs a temporary baseline, pass it through
`MCP_CONFORMANCE_EXPECTED_FAILURES` so stale baselines fail loudly. Use `MCP_CONFORMANCE_PACKAGE`
only for deliberate package upgrade experiments, and `MCP_CONFORMANCE_NPM_CACHE` when the default
npm cache is not writable.

Some official conformance scenarios are fixture-specific. For example, `json-schema-2020-12` checks
for a special tool named `json_schema_2020_12_tool`; it does not merely validate that every real
server tool uses draft 2020-12. Tool-call scenarios likewise expect conformance fixture tools unless
the server exposes compatible tools or carries an expected-failure baseline.

## Important Next Gap

If Monte Carlo style proof search is an important use case, the next missing regression is a larger
search workload that:

- starts from one preserved proof basis
- performs many more `runWith` playouts than the current seeded regression
- branches both linearly and non-linearly at greater depth
- mixes semantic failure, success, cancellation, and stale invalidation
- verifies that old and successor handles behave correctly under heavier branching pressure
- begins to approximate realistic tree-policy plus playout workloads rather than a small correctness loop

That would move the repo from “search-style correctness coverage exists” toward “search workloads
are stressed in a way that looks like real proof search.”
