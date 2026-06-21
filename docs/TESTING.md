# Testing

The repository treats testing as three distinct surfaces:

- `LSP`: every method registered by the Lean plugin in [RunAt/Plugin.lean](../RunAt/Plugin.lean)
- `Beam`: broker, daemon/client protocol, CLI wrapper, install/runtime packaging, MCP, toolchain support, and Rocq support
- `Maintainer`: local workflow helpers and defensive validation wrappers that are not part of the product surface

This split is organizational. It is also the supported top-level test layout.

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

## LSP Surface

Primary entrypoint:

- [tests/test-lsp.sh](../tests/test-lsp.sh)

Current LSP coverage includes:

- interactive file-anchored regressions through [tests/interactive](../tests/interactive) and [RunAtTest/TestRunner.lean](../RunAtTest/TestRunner.lean)
- multi-document and async scenario coverage through [tests/scenario](../tests/scenario) and [RunAtTest/ScenarioRunner.lean](../RunAtTest/ScenarioRunner.lean)
- programmatic scenario API coverage in [RunAtTest/Scenario/ApiTest.lean](../RunAtTest/Scenario/ApiTest.lean)
- shuffled concurrent workload coverage in [RunAtTest/Scenario/StressTest.lean](../RunAtTest/Scenario/StressTest.lean)
- handle API, restart, lifecycle, and nested-failure coverage in [RunAtTest/Handle](../RunAtTest/Handle)
- full registered LSP request coverage in [RunAtTest/RequestSurfaceTest.lean](../RunAtTest/RequestSurfaceTest.lean), including `$/lean/todo` and `$/lean/runAt` composition
- search-style handle workflows in [RunAtTest/Scenario/MctsProofSearchTest.lean](../RunAtTest/Scenario/MctsProofSearchTest.lean)
- parallel multi-sorry workflow coverage in [RunAtTest/Scenario/ParallelGrindBatchTest.lean](../RunAtTest/Scenario/ParallelGrindBatchTest.lean), which queries actionable todos with `$/lean/todo`, validates one `$/lean/runAt` request per returned item, and then mirrors those exact replacements in one atomic batched `didChange`
- lightweight search-workload latency reporting in [RunAtTest/Scenario/SearchWorkloadReport.lean](../RunAtTest/Scenario/SearchWorkloadReport.lean) and [scripts/search-workload-report.sh](../scripts/search-workload-report.sh)

Run the LSP surface when the change touches request semantics, proof-vs-command basis selection, positions, cancellation, handles, stale snapshots, per-request isolation, or any method in [RunAt/Plugin.lean](../RunAt/Plugin.lean).

## Beam Surface

Default Beam entrypoints:

- [tests/test-beam-fast.sh](../tests/test-beam-fast.sh): fast broker stream, barrier, request-contract, MCP projection, and MCP smoke coverage
- [tests/test-beam-slow.sh](../tests/test-beam-slow.sh): wrapper, MCP stdio stress, sandbox-wrapper, and save-replay coverage
- [tests/test-beam-install.sh](../tests/test-beam-install.sh): installer and installed-runtime layout
- [tests/test-beam.sh](../tests/test-beam.sh): aggregate default Beam surface

Additional Beam lanes:

- [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) `<toolchain>`: supported-toolchain bundle validation
- [tests/test-beam-rocq.sh](../tests/test-beam-rocq.sh): Rocq broker and wrapper coverage
- [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh): external MCP conformance scenarios over the local Streamable HTTP bridge

Current Beam coverage includes:

- fast Beam daemon smoke, request-stream, save-stream, startup-handshake, tracked-diagnostic dedup, and protocol tests through [tests/test-beam-fast.sh](../tests/test-beam-fast.sh)
- wrapper coverage through [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh), which aggregates focused probe, runtime, sync/save, handle, and diagnostic slices
- focused daemon lifecycle coverage in [tests/test-beam-wrapper-daemon.sh](../tests/test-beam-wrapper-daemon.sh)
- Linux-only PID-isolated sandbox wrapper coverage in [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh)
- zero-build save replay and stale-save race coverage in [tests/test-broker-save-olean.sh](../tests/test-broker-save-olean.sh)
- install flow, installed runtime layout, manifest metadata, `supported-toolchains`, `doctor`, and installed MCP wrapper coverage in [tests/test-beam-install.sh](../tests/test-beam-install.sh)
- MCP protocol, projection, stdio, HTTP bridge, self-check, and external conformance coverage
- Rocq wrapper and broker smoke coverage in [tests/test-beam-wrapper-rocq.sh](../tests/test-beam-wrapper-rocq.sh) and [RunAtTest/Broker/RocqSmokeTest.lean](../RunAtTest/Broker/RocqSmokeTest.lean)

Run the Beam surface when the change touches broker protocol or transport, request/progress/diagnostics streams, daemon session or restart logic, wrapper CLI behavior, bundle resolution, install layout, `doctor`, `supported-toolchains`, save replay, save barriers, MCP, or Rocq integration.

## Maintainer Surface

The maintainer surface covers local workflow helpers:

- [tests/test-maintainer.sh](../tests/test-maintainer.sh)
- [tests/test-codex-harness.sh](../tests/test-codex-harness.sh)
- [tests/test-validate-defensive.sh](../tests/test-validate-defensive.sh)

The aggregate maintainer runner skips [tests/test-codex-harness.sh](../tests/test-codex-harness.sh) when the current checkout has tracked edits, because that harness regression intentionally verifies that new task worktrees start from a clean primary checkout.

Run these when the change touches [scripts/codex-harness.sh](../scripts/codex-harness.sh), [scripts/codex-session-start.sh](../scripts/codex-session-start.sh), or [scripts/validate-defensive.sh](../scripts/validate-defensive.sh).

## CI Map

The current GitHub Actions workflow maps to the testing surfaces like this:

- `lsp`: [tests/test-lsp.sh](../tests/test-lsp.sh)
- `beam-fast`: [tests/test-beam-fast.sh](../tests/test-beam-fast.sh)
- `mcp-conformance`: [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh)
- `beam-slow`: [tests/test-beam-slow.sh](../tests/test-beam-slow.sh)
- `beam-install`: [tests/test-beam-install.sh](../tests/test-beam-install.sh)
- `beam-toolchain-compat`: [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) `<toolchain>`
- `beam-rocq`: [tests/test-beam-rocq.sh](../tests/test-beam-rocq.sh)
- `shell-lint`: [scripts/lint-shell.sh](../scripts/lint-shell.sh)

## Coverage Gaps

The main current gaps are:

- search-style LSP coverage is correctness-heavy, but not yet a larger benchmark-style workload with much deeper branching pressure
- the Beam `deps` path is still mostly covered by happy-path smoke checks even though [Beam/Broker/Deps.lean](../Beam/Broker/Deps.lean) is explicitly a stopgap scanner
- maintainer-surface regressions are documented and runnable, but separate from the default product CI lanes
