# Testing

This is contributor and maintainer documentation. Normal Lean Beam users should not need to read
this document to install or use the CLI.

CI is the validation record for routine checks. PR descriptions should mention tests only for rare
local validation that CI cannot represent; see [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests).

The repository treats testing as three distinct surfaces:

- `LSP`: every method registered by the Lean plugin in [Beam/LSP/Plugin.lean](../Beam/LSP/Plugin.lean)
- `Beam`: broker, daemon/client protocol, CLI wrapper, install/runtime packaging, MCP, toolchain support, and Rocq support
- `Maintainer`: local workflow helpers and defensive validation wrappers that are not part of the product surface

This split is organizational. It is also the supported top-level test layout.

Importable Lean test code lives under [tests/lean/BeamTest](../tests/lean/BeamTest) and is exposed
to Lake as the `BeamTest` library. The rest of [tests](../tests) contains shell and Python
entrypoints, scenario scripts, interactive golden inputs, fixture projects, and shared test helper
scripts.

The LSP surface also has a lightweight coverage registry under
[tests/lsp-coverage](../tests/lsp-coverage). The registry ties every method registered by
[Beam/LSP/Plugin.lean](../Beam/LSP/Plugin.lean) to concrete test pointers and required coverage
tags such as isolation, stale-edit, cancellation, handle lifecycle, and mixed concurrency.
Method-isolated Lean request tests live under
[tests/lean/BeamTest/LSP/Requests](../tests/lean/BeamTest/LSP/Requests), with
[tests/lean/BeamTest/LSP/RequestSurfaceTest.lean](../tests/lean/BeamTest/LSP/RequestSurfaceTest.lean)
remaining as the aggregate request-surface runner.

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
- [tests/lsp-coverage/check.py](../tests/lsp-coverage/check.py) validates LSP coverage metadata
  before the executable LSP tests run.

Current LSP coverage includes:

- interactive file-anchored regressions through [tests/interactive](../tests/interactive) and [tests/lean/BeamTest/LSP/TestRunner.lean](../tests/lean/BeamTest/LSP/TestRunner.lean)
- multi-document and async scenario coverage through [tests/scenario](../tests/scenario) and [tests/lean/BeamTest/LSP/ScenarioRunner.lean](../tests/lean/BeamTest/LSP/ScenarioRunner.lean)
- programmatic scenario API coverage in [tests/lean/BeamTest/LSP/Scenario/ApiTest.lean](../tests/lean/BeamTest/LSP/Scenario/ApiTest.lean)
- shuffled concurrent workload coverage in [tests/lean/BeamTest/LSP/Scenario/StressTest.lean](../tests/lean/BeamTest/LSP/Scenario/StressTest.lean)
- handle API, restart, lifecycle, and nested-failure coverage in [tests/lean/BeamTest/LSP/Handle](../tests/lean/BeamTest/LSP/Handle)
- full registered LSP request coverage through request-family tests under [tests/lean/BeamTest/LSP/Requests](../tests/lean/BeamTest/LSP/Requests), aggregated by [tests/lean/BeamTest/LSP/RequestSurfaceTest.lean](../tests/lean/BeamTest/LSP/RequestSurfaceTest.lean), including `$/lean/todo` and `$/lean/runAt` composition
- search-style handle workflows in [tests/lean/BeamTest/LSP/Scenario/MctsProofSearchTest.lean](../tests/lean/BeamTest/LSP/Scenario/MctsProofSearchTest.lean)
- parallel multi-sorry workflow coverage in [tests/lean/BeamTest/LSP/Scenario/ParallelGrindBatchTest.lean](../tests/lean/BeamTest/LSP/Scenario/ParallelGrindBatchTest.lean), which queries actionable todos with `$/lean/todo`, validates one `$/lean/runAt` request per returned item, and then mirrors those exact replacements in one atomic batched `didChange`
- lightweight search-workload latency reporting in [tests/lean/BeamTest/LSP/Scenario/SearchWorkloadReport.lean](../tests/lean/BeamTest/LSP/Scenario/SearchWorkloadReport.lean) and [scripts/search-workload-report.sh](../scripts/search-workload-report.sh)

Run the LSP surface when the change touches request semantics, proof-vs-command basis selection, positions, cancellation, handles, stale snapshots, per-request isolation, or any method in [Beam/LSP/Plugin.lean](../Beam/LSP/Plugin.lean).

## Beam Surface

Default Beam entrypoints:

- [tests/test-beam-fast.sh](../tests/test-beam-fast.sh): fast broker stream, barrier, request-contract, MCP projection, MCP smoke, and toolchain CI-matrix guard coverage
- [tests/test-beam-slow.sh](../tests/test-beam-slow.sh): wrapper, MCP stdio stress, sandbox-wrapper, and save-replay coverage
- [tests/test-beam-install.sh](../tests/test-beam-install.sh): installer and installed-runtime layout
- [tests/test-beam.sh](../tests/test-beam.sh): aggregate default Beam surface

Additional Beam lanes:

- [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) `<toolchain>`: supported-toolchain bundle validation and stale-import diagnostic wording compatibility
- [tests/test-beam-rocq.sh](../tests/test-beam-rocq.sh): Rocq broker and wrapper coverage
- [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh): external MCP conformance scenarios over the local Streamable HTTP bridge

Current Beam coverage includes:

- fast Beam daemon smoke, request-stream, save-stream, startup-handshake, tracked-diagnostic dedup, protocol tests, and supported-toolchain CI matrix consistency through [tests/test-beam-fast.sh](../tests/test-beam-fast.sh)
- wrapper coverage through [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh), which aggregates focused probe, runtime, sync/save, handle, and diagnostic slices
- focused daemon lifecycle coverage in [tests/test-beam-wrapper-daemon.sh](../tests/test-beam-wrapper-daemon.sh)
- Linux-only PID-isolated sandbox wrapper coverage in [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh)
- zero-build save replay and stale-save race coverage in [tests/test-beam-save-olean.sh](../tests/test-beam-save-olean.sh)
- install flow, installed runtime layout, manifest metadata, `supported-toolchains`, `doctor`, and installed MCP wrapper coverage in [tests/test-beam-install.sh](../tests/test-beam-install.sh)
- MCP protocol, projection, stdio, HTTP bridge, self-check, and external conformance coverage
- Rocq wrapper and broker smoke coverage in [tests/test-beam-wrapper-rocq.sh](../tests/test-beam-wrapper-rocq.sh) and [tests/lean/BeamTest/Broker/RocqSmokeTest.lean](../tests/lean/BeamTest/Broker/RocqSmokeTest.lean)

Run the Beam surface when the change touches broker protocol or transport, request/progress/diagnostics streams, daemon session or restart logic, wrapper CLI behavior, bundle resolution, install layout, `doctor`, `supported-toolchains`, save replay, save barriers, MCP, or Rocq integration.

The user-facing installer behavior, write locations, MCP registration paths, and toolchain options
are documented in [INSTALL.md](INSTALL.md). The notes below cover maintainer test fixtures and
offline validation knobs.

`tests/test-beam-install.sh` uses fresh fake homes, so first runs may otherwise download Lean
toolchains repeatedly. By default it opportunistically pre-seeds each fake `ELAN_HOME` with symlinks
to matching toolchains already present in the host elan cache. Set
`BEAM_INSTALL_TEST_PRESEED_ELAN=0` to force fully fresh fake homes, or set
`BEAM_INSTALL_TEST_PRESEED_ELAN=require` when working on a slow/offline connection and you want the
test to fail fast if a supported toolchain is missing from the host cache.

Installer tests should keep filesystem side effects inside their fake homes and owned temp roots.
Use [tests/lib/install-fixtures.sh](../tests/lib/install-fixtures.sh) for installer-specific
fixtures and [tests/lib/tmp-guards.sh](../tests/lib/tmp-guards.sh) for generic shell-test cleanup
guards. New tests that remove temp paths should declare their expected `/tmp` prefix explicitly and
use the guard helpers instead of raw `rm -rf`; the helpers also allow the nested
`/tmp/beam-validate-*/tmp/...` layout used by [scripts/validate-defensive.sh](../scripts/validate-defensive.sh).

For slow or offline validation, pre-seed the host elan cache before running installer tests. A
typical setup is:

```bash
grep -v '^[[:space:]]*#' supported-lean-toolchains | sed '/^[[:space:]]*$/d' |
  while IFS= read -r toolchain; do
    elan toolchain install "$toolchain"
  done

BEAM_INSTALL_TEST_PRESEED_ELAN=require bash tests/test-beam-install.sh
```

Use [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) to validate one
supported bundle lane at a time. The lane also checks that Lean's stale-import diagnostic wording
still matches Beam's temporary text-based detector while the structured Lean stale-dependency API is
pending. If bundle installation stalls on a slow machine, raise
`BEAM_TOOLCHAIN_COMPAT_TIMEOUT` from its default 600 seconds. On failure, the test prints the fake
home, Codex/Claude homes, bundle directory, platform, and captured build/bundle/stale-diagnostic
log tails so the bundle or stale-diagnostic state can be diagnosed from the test log. Set
`BEAM_TOOLCHAIN_COMPAT_KEEP_TMP_ON_FAILURE=1` to preserve the fake roots for local inspection after
a failed run.

## Save Replay Timeout Investigation

[tests/test-beam-save-olean.sh](../tests/test-beam-save-olean.sh) includes a save-race case
that injects a slow Lean command into `SaveSmoke/B.lean`. The command writes
`LEAN_BEAM_SAVE_RACE_SENTINEL` when elaboration reaches the intended race window, then sleeps long
enough for the shell test to edit the source file while `lean-close-save` is still in flight.

If the sentinel is not written before `BEAM_SAVE_RACE_SENTINEL_TIMEOUT` (default 60 seconds), the
test now dumps the active save PID, runner CPU/platform context, Beam/Lean process snapshot, current
`SaveSmoke/B.lean`, the sentinel file state, daemon registry, daemon log tail, and captured save
stdout/stderr. The race and cancel-sentinel cases start their daemon with broker trace enabled by
default (`BEAM_SAVE_RACE_BROKER_TRACE=1`) and a diagnostics-barrier watchdog
(`BEAM_SAVE_RACE_WAIT_DIAGNOSTICS_WATCHDOG_MS=10000`) so macOS/low-core stalls preserve useful
phase information in the daemon log.

## MCP Stdio Timeout Investigation

When investigating MCP stdio timeouts, prefer the focused roots-negotiated sync repro before
rerunning the full smoke suite:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/test-mcp-stdio.py \
  --scenario progress-roots-sync \
  --repro-runs 100 \
  --timeout 30 \
  --slow-threshold 5 \
  --server-trace
```

That scenario repeats the path that negotiates workspace roots through MCP `roots/list`, runs
`lean_sync` with a progress token, and checks the resulting progress notifications. On failure, the
timeout report includes the client label, pending request parameters, recent completed requests,
recent server requests received from `lean-beam-mcp`, recent notifications, runner CPU/platform
context, relevant CI and Lean thread env vars, the stderr tail, and a Beam/Lean process snapshot.
If this scheduler-sensitive timeout appears on an unrelated CI PR, copy the timeout headline and
diagnostic excerpt to [#110](https://github.com/ejgallego/lean-beam/issues/110) so repeated
occurrences can be correlated in one place. Include the PR URL and branch, failing run URL, failing
job URL, job name, runner OS/arch, run attempt, commit SHA, failing test or scenario, relevant
request/progress or sentinel diagnostics from the log, and the rerun URL plus whether it passed or
reproduced.
The optional `--server-trace` flag enables opt-in `lean-beam-mcp` and broker trace lines in that
stderr tail without changing normal test stderr expectations. To look for scheduler-sensitive
behavior locally, prefer a low-core or CPU-contended run. On a large local machine, run CPU load in
one shell:

```bash
stress-ng --cpu 24 --timeout 90s --metrics-brief
```

Then run the focused scenario in another shell while the stressors are active.

For the scheduler-sensitive progress-smoke path that has reproduced timeouts locally, use the
parallel repro scenario while the stressors are active:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/test-mcp-stdio.py \
  --scenario progress-smoke-parallel \
  --parallel-workers 8 \
  --repro-runs 10 \
  --timeout 30 \
  --slow-threshold 5
```

Set `--server-trace` to add MCP/broker trace lines to the timeout dump, and set
`LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS=10000` to emit an opt-in broker trace if a
`waitForDiagnostics` barrier is still pending after that many milliseconds. The regular CI Beam
suites run the stdio smoke with `BEAM_MCP_STDIO_TIMEOUT` defaulting to 60 seconds, enable
`BEAM_MCP_SERVER_TRACE=1` for the stdio harness by default, and set the diagnostics-barrier watchdog
to `BEAM_MCP_STDIO_WAIT_DIAGNOSTICS_WATCHDOG_MS=10000`. Set `BEAM_MCP_STDIO_SERVER_TRACE=0` only
when intentionally checking the quiet stderr path. The fast suite's installed-wrapper self-check uses
`BEAM_MCP_SELF_CHECK_TIMEOUT_MS`, defaulting to 120 seconds, because first-time bundle setup may
build the local fixture under CI contention. Keep `--timeout 30` for local repro attempts unless you
are specifically checking the CI budget.

The focused harness also accepts `progress-explicit-sync`, `no-progress-roots-sync`, and
`no-progress-explicit-sync` as `--scenario` values. Use those variants to isolate whether a timeout
depends on MCP roots negotiation, MCP progress notifications, or the underlying `lean_sync` /
`waitForDiagnostics` path.

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
- maintainer-surface regressions are documented and runnable, but separate from the default product CI lanes
