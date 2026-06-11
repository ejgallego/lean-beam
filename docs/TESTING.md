# Testing

This is contributor and maintainer documentation. Normal Lean Beam users should not need to read
this document to install or use the CLI.

CI is the validation record for routine checks. PR descriptions should mention tests only for rare
local validation that CI cannot represent; see [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests).

## Which Suite Should I Run?

| Change area | Start with | Add when needed |
| --- | --- | --- |
| Core Lean `runAt` semantics | [tests/test.sh](../tests/test.sh) | Add focused scenario files when changing request behavior. |
| Broker protocol, request streams, barriers, or MCP projection | [tests/test-broker-fast.sh](../tests/test-broker-fast.sh) | Use the aggregate broker suite before landing broad broker changes. |
| Wrapper, install flow, bundle resolution, daemon lifecycle, or MCP reliability | [tests/test-broker-slow.sh](../tests/test-broker-slow.sh) | Use [scripts/validate-defensive.sh](../scripts/validate-defensive.sh) for risky local install or wrapper validation. |
| Rocq broker or wrapper behavior | [tests/test-broker-rocq.sh](../tests/test-broker-rocq.sh) | Keep Rocq checks separate from Lean-specific workflow changes. |
| Shell wrappers, installer, or shell test harnesses | [scripts/lint-shell.sh](../scripts/lint-shell.sh) | CI runs the same `shellcheck` pass. |
| Broad broker-facing changes | [tests/test-broker.sh](../tests/test-broker.sh) | This runs the aggregate broker signal. |

Slow-suite steps are grouped and timed in CI through [tests/lib/ci-steps.sh](../tests/lib/ci-steps.sh).
Multi-command functions passed to `run_step` must return failures explicitly, because the helper
keeps control long enough to print timing and close GitHub log groups.

## Coverage Map

### Core Lean And `runAt`

The core Lean behavior is covered by:

- interactive file-anchored regressions through [tests/test.sh](../tests/test.sh)
- multi-document and async behavior through the scenario DSL in [tests/scenario](../tests/scenario)
- programmable scenario coverage through [RunAtTest/Scenario.lean](../RunAtTest/Scenario.lean)
- shuffled concurrent workload coverage through
  [RunAtTest/Scenario/StressTest.lean](../RunAtTest/Scenario/StressTest.lean)
- request-surface assertions in
  [RunAtTest/RequestSurfaceTest.lean](../RunAtTest/RequestSurfaceTest.lean)
- lightweight search-workload latency reporting in
  [RunAtTest/Scenario/SearchWorkloadReport.lean](../RunAtTest/Scenario/SearchWorkloadReport.lean)
  and [scripts/search-workload-report.sh](../scripts/search-workload-report.sh)

Follow-up handle behavior is covered by:

- scenario DSL files such as
  [tests/scenario/handleDsl.scn](../tests/scenario/handleDsl.scn),
  [tests/scenario/handleLinearDsl.scn](../tests/scenario/handleLinearDsl.scn),
  [tests/scenario/handleNestedBranchDsl.scn](../tests/scenario/handleNestedBranchDsl.scn),
  [tests/scenario/handleProofBranchDsl.scn](../tests/scenario/handleProofBranchDsl.scn),
  [tests/scenario/handleSearchCancelDsl.scn](../tests/scenario/handleSearchCancelDsl.scn),
  [tests/scenario/handleCancelDsl.scn](../tests/scenario/handleCancelDsl.scn), and
  [tests/scenario/handleInvalidationDsl.scn](../tests/scenario/handleInvalidationDsl.scn)
- handle API assertions in
  [RunAtTest/Handle/ApiTest.lean](../RunAtTest/Handle/ApiTest.lean) and
  [RunAtTest/Handle/RestartTest.lean](../RunAtTest/Handle/RestartTest.lean)
- nested handle failure-shape assertions in
  [RunAtTest/Handle/NestedHandleFailureTest.lean](../RunAtTest/Handle/NestedHandleFailureTest.lean)

### Search-Style Handles

The seeded MCTS-style proof-search regression lives in
[RunAtTest/Scenario/MctsProofSearchTest.lean](../RunAtTest/Scenario/MctsProofSearchTest.lean).

That test exercises:

- repeated playouts from one preserved proof handle
- non-linear branching from the same recovered basis
- linear continuation on derived handles
- semantic-failure probes that must not mutate preserved handles
- linear failure probes that must consume the current handle
- cancellation on branched proof-search handles, including preserved-parent reuse and linear-handle
  consumption
- explicit release of explored side branches
- stale invalidation of live search handles after a document edit
- nested semantic failures that preserve proof-state payloads, suppress successor handles, and still
  distinguish non-linear from linear handle reuse

This sits on top of earlier search-enabling coverage:

- non-linear proof branching in
  [tests/scenario/handleProofBranchDsl.scn](../tests/scenario/handleProofBranchDsl.scn)
- programmable request orchestration through [RunAtTest/Scenario.lean](../RunAtTest/Scenario.lean)
- shuffled concurrent workload coverage in
  [RunAtTest/Scenario/StressTest.lean](../RunAtTest/Scenario/StressTest.lean)
- nested multi-goal cursor corner cases in
  [tests/interactive/proofNestedConstructorOrder.lean](../tests/interactive/proofNestedConstructorOrder.lean),
  [tests/interactive/proofNestedBulletWhitespace.lean](../tests/interactive/proofNestedBulletWhitespace.lean),
  and [tests/interactive/proofNestedRightSibling.lean](../tests/interactive/proofNestedRightSibling.lean)
- nested right-sibling handle continuation in
  [tests/scenario/handleNestedRightBranchDsl.scn](../tests/scenario/handleNestedRightBranchDsl.scn)

The current search test is a correctness regression, not a performance benchmark.

### Broker And Wrapper

Broker and wrapper behavior is covered by:

- fast Beam daemon smoke coverage in [tests/test-broker-fast.sh](../tests/test-broker-fast.sh),
  including completed barrier progress vs partial request progress expectations
- broker protocol envelope coverage in
  [RunAtTest/Broker/ProtocolTest.lean](../RunAtTest/Broker/ProtocolTest.lean), including explicit
  `ok` fields, legacy inferred-`ok` decoding, and rejection of inconsistent error/result envelopes
- CLI daemon helper coverage in
  [RunAtTest/Broker/CliDaemonTest.lean](../RunAtTest/Broker/CliDaemonTest.lean), including startup
  retry policy, lock lifecycle, deterministic runtime bundle helper path / identity behavior, and
  runtime bundle metadata schema versioning / acceptance rules
- experimental Lean broker `request_at` coverage through
  [RunAtTest/Broker/SmokeTest.lean](../RunAtTest/Broker/SmokeTest.lean) and
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- explicit `lean-beam sync` regression coverage for diagnostics-wait behavior and compact
  `fileProgress.done` reporting in [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- wrapper coverage for alpha Lean handle mint / continue / linear-continue / release flows in
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- wrapper coverage for the installed `lean-beam-search` helper in
  [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh)
- focused wrapper daemon lifecycle coverage in
  [tests/test-beam-wrapper-daemon.sh](../tests/test-beam-wrapper-daemon.sh), including
  `lean-beam ensure --hold`, stale same-namespace wrapper lease cleanup, endpoint collisions, stale
  registries, and non-Beam busy-port rejection
- shared wrapper shell helpers in
  [tests/lib/beam-wrapper-common.sh](../tests/lib/beam-wrapper-common.sh)
- PID-isolated sandbox wrapper coverage in
  [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh); this regression is
  Linux-only because it depends on `bwrap`
- zero-build save regression coverage in
  [tests/test-broker-save-olean.sh](../tests/test-broker-save-olean.sh), including exact-target
  replay, downstream importer reuse after daemon shutdown, and a timed stale-save race
- repo-local Codex worktree discipline coverage in
  [tests/test-codex-harness.sh](../tests/test-codex-harness.sh)

### MCP

MCP behavior is covered as a layered maintainer gate:

- projection boundary coverage in
  [RunAtTest/Broker/McpProjectionTest.lean](../RunAtTest/Broker/McpProjectionTest.lean)
- protocol/server coverage in
  [RunAtTest/Broker/McpProtocolTest.lean](../RunAtTest/Broker/McpProtocolTest.lean)
- Lean-backed stdio coverage in [tests/test-mcp-stdio.py](../tests/test-mcp-stdio.py)
- local Streamable HTTP bridge coverage in
  [tests/test-mcp-http-bridge.py](../tests/test-mcp-http-bridge.py)
- external conformance coverage through
  [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh)
- installed runtime and wrapper coverage in [tests/test-install.sh](../tests/test-install.sh)

Current MCP architecture, versioning, error-shape, and conformance details live in
[docs/MCP.md](MCP.md).

### CI

GitHub Actions validates the main CI job set from
[.github/workflows/ci.yml](../.github/workflows/ci.yml) on Ubuntu and macOS. The matrix includes
broker smoke coverage and MCP conformance coverage on both platforms. CI workflow actions use
Node 24-compatible first-party action majors; the `mcp-conformance` `node-version` setting is the
JavaScript test runtime, not the GitHub Action runtime.

## Known Gaps

The next search-workload gap is a larger benchmark-style regression that:

- starts from one preserved proof basis
- performs many more `runWith` playouts than the current seeded regression
- branches both linearly and non-linearly at greater depth
- mixes semantic failure, success, cancellation, and stale invalidation
- verifies old and successor handles under heavier branching pressure
- approximates realistic tree-policy plus playout workloads rather than a small correctness loop

That would move the repo from search-style correctness coverage toward search workloads stressed in
a way that looks like real proof search.
