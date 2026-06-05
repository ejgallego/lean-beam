# Testing

The current test story is good for an alpha repository, but it is recent and mostly end-to-end.

Most of the harness was built over March 10-11, 2026. Coverage is strongest around externally
visible behavior: request semantics, stale-state handling, cancellation, handle invalidation, and
Beam daemon integration.

## Current Coverage

- interactive file-anchored regressions through [tests/test.sh](../tests/test.sh)
- multi-document and async behavior through the scenario DSL in [tests/scenario](../tests/scenario)
- programmable scenario coverage through [RunAt/Scenario.lean](../RunAt/Scenario.lean)
- shuffled concurrent workload coverage through [RunAt/ScenarioStressTest.lean](../RunAt/ScenarioStressTest.lean)
- follow-up handle coverage through [tests/scenario/handleDsl.scn](../tests/scenario/handleDsl.scn),
  [tests/scenario/handleLinearDsl.scn](../tests/scenario/handleLinearDsl.scn),
  [tests/scenario/handleNestedBranchDsl.scn](../tests/scenario/handleNestedBranchDsl.scn),
  [tests/scenario/handleProofBranchDsl.scn](../tests/scenario/handleProofBranchDsl.scn),
  [tests/scenario/handleSearchCancelDsl.scn](../tests/scenario/handleSearchCancelDsl.scn),
  [tests/scenario/handleCancelDsl.scn](../tests/scenario/handleCancelDsl.scn), and
  [tests/scenario/handleInvalidationDsl.scn](../tests/scenario/handleInvalidationDsl.scn)
- handle-specific API assertions in [RunAt/HandleApiTest.lean](../RunAt/HandleApiTest.lean) and
  [RunAt/HandleRestartTest.lean](../RunAt/HandleRestartTest.lean)
- nested handle failure-shape assertions in
  [RunAt/NestedHandleFailureTest.lean](../RunAt/NestedHandleFailureTest.lean)
- fast Beam daemon smoke coverage in [tests/test-broker-fast.sh](../tests/test-broker-fast.sh),
  including completed barrier progress vs partial request progress expectations
- broker protocol envelope coverage in
  [RunAtTest/Broker/ProtocolTest.lean](../RunAtTest/Broker/ProtocolTest.lean), including explicit
  `ok` fields on produced responses, legacy inferred-`ok` decoding, and rejection of inconsistent
  error/result envelopes
- MCP projection boundary coverage in
  [RunAtTest/Broker/McpProjectionTest.lean](../RunAtTest/Broker/McpProjectionTest.lean), including
  supported Lean tool names, rejection of raw LSP method names and expert raw request escape
  hatches, shared typed operation-to-broker adapters, root-free MCP inputs, and normalized
  `next_handle` / `proof_state` output for runAt-style results
- MCP protocol/server coverage in
  [RunAtTest/Broker/McpProtocolTest.lean](../RunAtTest/Broker/McpProtocolTest.lean), including
  JSON-RPC request/notification decoding, initialize/tools-list response shape, generated tool
  schemas, initialize / initialized lifecycle gating, raw LSP rejection, malformed-tool protocol
  errors, known-tool input validation as MCP tool execution errors, roots capability detection, and
  `roots/list` response decoding
- Lean-backed `lean-beam-mcp` stdio coverage in
  [tests/test-mcp-stdio.py](../tests/test-mcp-stdio.py), which runs initialize, initialized
  notification, tools/list, raw-tool rejection, sync, runAt semantic success/failure, handle
  mint/continue/linear/release, goals, close, shutdown, a table-driven lifecycle matrix,
  explicit-root startup, MCP `roots/list` project-root discovery, root setup error cases, stdout
  JSON parsing, and stderr hygiene assertions against a copied Lean fixture project. Stderr hygiene
  is a local regression check, not an MCP requirement; the `2025-11-25` stdio transport explicitly
  permits server logging on stderr.
- local Streamable HTTP bridge coverage in
  [tests/test-mcp-http-bridge.py](../tests/test-mcp-http-bridge.py), which starts
  [tests/mcp_http_bridge.py](../tests/mcp_http_bridge.py) against a `lean-beam-mcp` stdio child and
  checks HTTP status behavior, `Origin` rejection, unsupported `MCP-Protocol-Version` rejection,
  initialize / initialized lifecycle, tools/list, raw-tool rejection, known-tool input errors, a real
  `lean_sync` call, and shutdown
- a lightweight `lean-beam-mcp` stdio smoke in
  [tests/test-broker-fast.sh](../tests/test-broker-fast.sh), which keeps a cheap newline-delimited
  protocol path check that does not require a Lean worker process
- GitHub Actions main coverage in [.github/workflows/ci.yml](../.github/workflows/ci.yml), whose
  Linux job set now also runs on `macos-latest`
- GitHub Actions broker smoke coverage on both Ubuntu and macOS through the matrixed
  `broker-fast` job in [.github/workflows/ci.yml](../.github/workflows/ci.yml)
- GitHub Actions MCP conformance coverage on both Ubuntu and macOS through the matrixed
  `mcp-conformance` job, which runs the pinned external conformance package against the local
  Streamable HTTP bridge
- slower wrapper/install coverage in [tests/test-broker-slow.sh](../tests/test-broker-slow.sh)
- focused wrapper daemon lifecycle coverage in
  [tests/test-beam-wrapper-daemon.sh](../tests/test-beam-wrapper-daemon.sh), including
  `lean-beam ensure --hold`, stale same-namespace wrapper lease cleanup, endpoint collisions with
  another Beam root, stale registries that point at another root, and non-Beam busy-port rejection
- experimental Lean broker `request_at` coverage through
  [RunAtTest/Broker/SmokeTest.lean](../RunAtTest/Broker/SmokeTest.lean) and
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh), including whitelisted request
  success, stdin JSON extras, stats accounting, and rejection of user-supplied `textDocument` /
  `position` overrides
- explicit `lean-beam sync` regression coverage for diagnostics-wait behavior and compact
  `fileProgress.done` reporting in [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh),
  including stale-import cases where the diagnostics barrier must fail instead of reporting a
  partial success
- wrapper coverage for alpha Lean handle mint / continue / linear-continue / release flows in
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- wrapper coverage for the installed `lean-beam-search` helper in
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- PID-isolated sandbox wrapper coverage in
  [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh), which checks that a
  later sandboxed wrapper invocation reuses a live daemon via its endpoint and that overlapping
  wrapper requests on the same root do not kill each other's daemon mid-flight; this regression is
  Linux-only because it depends on `bwrap`
- zero-build save regression coverage in [tests/test-broker-save-olean.sh](../tests/test-broker-save-olean.sh),
  including exact-target replay, downstream importer reuse after daemon shutdown, and a timed
  race where a mid-save edit must leave the saved module stale for later `lake build`
- repo-local Codex worktree discipline coverage in [tests/test-codex-harness.sh](../tests/test-codex-harness.sh),
  which checks maintainer workflow helpers that start new tasks in dedicated worktrees and reject
  the primary checkout unless explicitly overridden
- lightweight search-workload latency reporting in
  [RunAtTest/Scenario/SearchWorkloadReport.lean](../RunAtTest/Scenario/SearchWorkloadReport.lean)
  and [scripts/search-workload-report.sh](../scripts/search-workload-report.sh)

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
- programmable request orchestration through [RunAt/Scenario.lean](../RunAt/Scenario.lean)
- shuffled concurrent workload coverage in
  [RunAt/ScenarioStressTest.lean](../RunAt/ScenarioStressTest.lean)
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
  Lean-backed MCP stdio pass; this is the quickest broker signal
- add [tests/test-broker-slow.sh](../tests/test-broker-slow.sh) when the change touches wrapper,
  install, bundle-resolution behavior, or MCP server reliability; it repeats the MCP stdio harness
  across several server restarts before running focused daemon lifecycle checks and the broader
  wrapper/install checks. Slow-suite steps are grouped and timed in CI through
  [tests/lib/ci-steps.sh](../tests/lib/ci-steps.sh).
- use [tests/test-broker-rocq.sh](../tests/test-broker-rocq.sh) for Rocq broker and wrapper
  coverage, including `coq-lsp` discovery from project-local `_opam` roots and the active PATH
- use [tests/test-broker.sh](../tests/test-broker.sh) to execute both suites together before
  landing a broader broker-facing change
- use [scripts/lint-shell.sh](../scripts/lint-shell.sh) when you change shell wrappers, installer,
  or shell-based test harnesses; CI runs the same `shellcheck` pass

## MCP Coverage Plan

The MCP server currently advertises protocol revision `2025-11-25` only. Version support should stay
narrow; adding another revision means updating `Beam.Mcp.protocolVersion` / version negotiation
policy, auditing schema and error-mapping changes, updating docs, and running both the local MCP
harness and external conformance coverage.

Current MCP gates are layered:

- protocol unit tests for JSON-RPC shapes, tool schemas, lifecycle gating, malformed-tool protocol
  errors, roots negotiation helpers, and known-tool input validation as tool execution errors
- projection tests for the shared Beam operation substrate and agent-facing field names
- `tests/test-mcp-stdio.py` for real stdio process behavior over a copied Lean project, including
  table-driven lifecycle/root setup cases, explicit `--root`, and client-advertised MCP roots
- `tests/test-mcp-http-bridge.py` for local Streamable HTTP transport behavior over the same stdio
  server
- `tests/test-broker-fast.sh` for one quick Lean-backed MCP stdio path, one HTTP bridge smoke, and a
  cheap protocol-only smoke; it also runs the public `lean-beam-mcp --self-check` path against the
  fixture project and negative setup checks for missing roots/files
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
Keep the scenario list explicit with `MCP_CONFORMANCE_SCENARIOS`; if a broader local run needs a
temporary baseline, pass it through `MCP_CONFORMANCE_EXPECTED_FAILURES` so stale baselines fail
loudly. Use `MCP_CONFORMANCE_PACKAGE` only for deliberate package upgrade experiments, and
`MCP_CONFORMANCE_NPM_CACHE` when the default npm cache is not writable.

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
