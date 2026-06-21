# Lean Beam

Lean Beam provides a Claude/Codex skill and local workflow layer for efficient interaction with
Lean 4. Under the hood, it combines a Lean 4 LSP server extension, the `$/lean/runAt` request for
cheap speculative execution, and a thin local broker that exposes a more idiomatic CLI and agent
surface over Lean's LSP and Beam-specific extensions.

Lean Beam is aimed at agent-heavy workflows such as proof repair,
porting from other systems to Lean, proof-search experimentation
including Monte Carlo Tree Search (MCTS), and autoformalization. For
agents making many edits to Lean files, Lean Beam can provide
asymptotic savings over repeating `lake build` after every change; see
the [cost model and workflow details](skills/lean-beam/references/workflow-details.md#cost-model).

Lean Beam started as a personal internal project and is now published for public use. It is not an
official Lean FRO product, the code remains experimental, and you should use it at your own risk.

Feedback is welcome; feel free to open issues or let us know what you think on Zulip.

## Install

Run the installer from the repo root:

```bash
./scripts/install-beam.sh
```

The default installer is interactive: it asks which Lean toolchains, agent skills, and
MCP client registrations to set up. It then shows a compact write summary and asks once for the Beam
runtime/wrapper install area, selected skill locations, and selected MCP config locations. For
non-interactive scripts, pass `--dont-ask`; this only skips prompts for requested Beam-owned
install/config paths and does not allow replacing unrelated user files.

That installs:

- `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` into `~/.local/bin`
- an immutable runtime under `BEAM_INSTALL_ROOT`, default `~/.local/share/beam`
- a prebuilt bundle for the repo-pinned supported Lean toolchain

Use `--codex`, `--claude`, or `--all-skills` to install the bundled agent skills:

```bash
./scripts/install-beam.sh --codex
./scripts/install-beam.sh --claude
./scripts/install-beam.sh --all-skills
```

Use `--codex-mcp`, `--claude-mcp`, or `--all-mcp` to register the installed `lean-beam-mcp` server
with Codex and/or Claude Code:

```bash
./scripts/install-beam.sh --codex-mcp
./scripts/install-beam.sh --claude-mcp
./scripts/install-beam.sh --all-mcp
```

Use `--toolchain <toolchain>` or `--all-supported` to prebuild additional validated Lean bundles:

```bash
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.31.0
./scripts/install-beam.sh --all-supported
```

If you are working on Lean itself or another local Lean build through an elan-linked toolchain, use
`--custom-toolchain <toolchain>` to explicitly accept and prebuild that toolchain for this Beam
install:

```bash
elan toolchain link lean4-dev /path/to/lean/build/release/stage1
./scripts/install-beam.sh --custom-toolchain lean4-dev
```

Custom toolchains are not validated release targets; Beam records them in the installed runtime's
`custom-lean-toolchains` registry and will only serve the exact custom names you installed. Bundle
keys also include the resolved Lean/Lake identity for that name, so relinking to a different local
build or changing the reported toolchain identity creates a different bundle instead of reusing
stale helpers. See [docs/CUSTOM_TOOLCHAINS.md](docs/CUSTOM_TOOLCHAINS.md) for the full custom
toolchain and runtime-bundle model.

## MCP Setup

The installer includes the experimental stdio MCP server as `lean-beam-mcp`. It can register the
server automatically for Codex, Claude Code, or both:

```bash
./scripts/install-beam.sh --codex-mcp
./scripts/install-beam.sh --claude-mcp
./scripts/install-beam.sh --all-mcp
```

To register an existing install manually, use an absolute path so the client can launch the server
even if `~/.local/bin` is not on its PATH:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
claude mcp add --scope user lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
```

MCP clients that support workspace roots can use that command as-is; Lean Beam discovers the project
root through `roots/list`. If a client does not provide roots, initialize one absolute Lean/Lake
project root per MCP server session with the `lean_init_workspace` tool before calling Lean tools:

```json
{"root":"/path/to/lean/project"}
```

The normal call omits `mode`. Advanced clients can use `mode: "verify"` to check the active root or
`mode: "reset"` to explicitly switch roots and invalidate handles; see
[docs/STATUS.md](docs/STATUS.md#mcp-workspace-initialization).
Successful `lean_init_workspace` results include a `capabilities` array with the projected MCP tool
names, including `lean_run_at`, `lean_sync`, `lean_save`, `lean_hover`, `lean_goals_prev`, and
`lean_goals_after`.

Direct developer runs and single-project MCP registrations may still pass an explicit project root:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp" --root /path/to/lean/project
claude mcp add --scope user lean-beam -- "$HOME/.local/bin/lean-beam-mcp" --root /path/to/lean/project
```

The `--root` startup flag accepts absolute paths and paths relative to the server's current working
directory. The `lean_init_workspace` tool intentionally accepts only absolute paths so clients do not
accidentally bind a session to a root interpreted from the server process cwd.

The wrapper resolves the matching installed `beam-cli`, Lean command, and runAt plugin for each
project. Direct developer runs of `.lake/build/bin/lean-beam-mcp` may still pass `--lean-cmd` and
`--lean-plugin` explicitly.

The MCP server advertises the MCP logging capability and forwards incremental Lean diagnostics from
sync/save-style tools as structured `notifications/message` events. These events include
`completionBlocking=true` when a diagnostic is known to block file completion. Save-blocking
evidence is reported on the final sync/save verdict through `blockingDiagnostics` and
`blockingCommandMessages`; the final tool result remains a compact state summary by default.
MCP clients that cannot conveniently collect interleaved notifications can call `lean_sync` with
`include_diagnostics: true` to also include the current request diagnostics in
`structuredContent.diagnostics`. Combine it with `full_diagnostics: true` when the reply should
include warnings, information, and hints instead of the default error-only diagnostic filter.
`full_diagnostics` is an output filter for streamed or replayed diagnostics; the
`syncSummary.diagnostics.current` counts still summarize the full current diagnostic state.

Client-facing reporting surfaces stay intentionally separate:

| Surface | Transport | Meaning |
| --- | --- | --- |
| Progress | `notifications/progress` | Request-scoped operation movement for clients that pass `_meta.progressToken`. |
| Diagnostics | `notifications/message` with logger `lean.diagnostic` | Incremental Lean diagnostics observed while a sync/save-style request is pending. |
| Readiness | Final structured tool result | Stable synced-state verdict for the document version, including save readiness and counts. |

`file_progress.line` and `file_progress.totalLines` are compact Lean file-progress range
observations, not a verified source line count. They can be useful for coarse UI progress, but
machine decisions should use the final readiness fields and diagnostics.

To verify the MCP path from a Lean project without writing JSON-RPC by hand, run:

```bash
lean-beam-mcp --root /path/to/lean/project --self-check MyPkg/Sub/Module.lean
```

The self-check starts a child MCP server, supplies the root through MCP `roots/list`, calls
`lean_sync` on the file, and shuts the child server down.

MCP clients can opt into live operation progress for `tools/call` requests by including
`params._meta.progressToken` as a string or integer. The field-level progress, diagnostic, and
sync-summary contract is maintained in
[docs/STATUS.md](docs/STATUS.md#progress-and-sync-delta-reporting).

## Supported Toolchains

Lean Beam serves validated Lean toolchains listed in
[`supported-lean-toolchains`](supported-lean-toolchains). It can also serve explicit custom
toolchains recorded at install time with `--custom-toolchain`; this is intended for local Lean
development toolchains and does not make those toolchains validated release targets. Runtime bundle
identity and custom-toolchain rules are documented in
[docs/CUSTOM_TOOLCHAINS.md](docs/CUSTOM_TOOLCHAINS.md).
Inspect the validated allowlist with:

```bash
lean-beam supported-toolchains
```

The current repo allowlist is:

```text
leanprover/lean4:v4.31.0
leanprover/lean4:v4.30.0
leanprover/lean4:v4.29.0
leanprover/lean4:v4.28.0
```

If you are unsure which runtime bundle is active or why a toolchain is rejected, use:

```bash
lean-beam doctor
```

## Agent-Facing Surface

For most agent-oriented workflows, the practical entry point is `lean-beam` together with the
workflow guidance in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md).

Common Lean commands:

```bash
lean-beam ensure
lean-beam ensure --hold
lean-beam hover "Foo.lean" 10 2
lean-beam goals-prev "Foo.lean" 10 2
lean-beam run-at "Foo.lean" 10 2 "exact trivial"
lean-beam deps "Foo.lean"
lean-beam sync "MyPkg/Sub/Module.lean"
lean-beam refresh "MyPkg/Sub/Module.lean"
lean-beam save "MyPkg/Sub/Module.lean"
```

Common MCP tool names:

| Wrapper command | MCP tool |
| --- | --- |
| `lean-beam run-at` | `mcp__lean_beam.lean_run_at` |
| `lean-beam hover` | `mcp__lean_beam.lean_hover` |
| `lean-beam goals-prev` | `mcp__lean_beam.lean_goals_prev` |
| `lean-beam goals-after` | `mcp__lean_beam.lean_goals_after` |
| `lean-beam sync` | `mcp__lean_beam.lean_sync` |
| `lean-beam save` | `mcp__lean_beam.lean_save` |

Read those commands like this:

- `lean-beam run-at` tries speculative Lean text without editing the file
- `lean-beam ensure --hold` is for PID-isolated command runners that need one foreground process
  to keep a newly-started daemon alive across separate wrapper calls
- `lean-beam deps` reports the broker's direct workspace dependency view for a path
- `lean-beam sync` is the explicit on-disk edit barrier after a real saved edit
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`
- `lean-beam save` checkpoints one synced workspace module; it does not validate downstream importers

Multiline and handle-oriented wrapper ergonomics:

```bash
# for multiline probe text, prefer stdin
printf 'example : True := by\n  trivial\n' | lean-beam run-at "Foo.lean" 10 2 --stdin

# for exact continuation, prefer a handle file
lean-beam run-at-handle "Foo.lean" 10 2 "constructor"
lean-beam run-with "Foo.lean" --handle-file handle.json "exact trivial"
```

Read those flags like this:

- `--stdin` is the normal multiline path for speculative Lean text
- `--handle-file <path>` is the normal handle path for exact continuation and release
- MCP workspace reset invalidates handles minted by the old runtime; discard saved handle files after
  `lean_init_workspace` with `mode: "reset"`
- deeper shell-oriented variants and debugging knobs live in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md) and the linked reference docs

The final `lean-beam sync` JSON summarizes the current synced version rather than replaying
diagnostics streamed on stderr for that request. Streamed diagnostics are request events, not a
since-last-sync diff. New tooling should prefer `result.syncSummary`: use
`readiness.current.saveReady` plus `saveBlockingErrorCount` for the save/checkpoint decision, and
use `diagnostics.current.*` only for Lean-published diagnostic severity counts. The flat
`result.errorCount`, `result.warningCount`, `result.saveReady`, `result.stateErrorCount`, and
`result.stateCommandErrorCount` fields remain compatibility projections of that current verdict.

`lean-beam save` includes the sync verdict it established before checkpointing in `result.sync`;
`lean-beam close-save` includes the same verdict in `result.saved.sync`. Document-error save
failures include that verdict in `error.data.sync`, so clients can inspect the synced version and
save-readiness decision that blocked checkpointing. See
[docs/STATUS.md](docs/STATUS.md#progress-and-sync-delta-reporting) for the exact progress,
diagnostic, readiness, and delta fields.

When `lean-beam sync` fails with `syncBarrierIncomplete`, the JSON error may include
`error.data.staleDirectDeps`, `error.data.saveDeps`, and `error.data.recoveryPlan` to suggest a
cheap direct-import recovery path before falling back to `lake build`. It may also include
`error.data.completionBlockingDiagnostics`; those entries carry `completionBlocking=true` because
the file could not reach the diagnostics-complete barrier for that version.

Detailed Lean workflow guidance lives in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md).
The narrower Rocq surface lives in [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md).

## Which Layer To Use

- Use `lean-beam` plus the installed skills if you want the practical agent workflow that integrates with Codex or Claude out of the box
- Use the Beam broker if you want one long-lived local process per project root while keeping a narrower local protocol than raw LSP
- Use the Lean LSP extension directly if you already own the LSP session and want the smallest typed surface, or if you want to build custom agents doing MCTS or other advanced setups

The public request and response types live in [RunAt/Protocol.lean](RunAt/Protocol.lean). The Lean
plugin implementation lives in [RunAt/Plugin.lean](RunAt/Plugin.lean).

## How The Code Is Organized

- `RunAt`: Lean LSP server plugin providing the `$/lean/runAt` request for speculative execution at arbitrary document points
- `Beam`: local broker, daemon/client pair, and CLI wrappers exposing a narrower agent-facing surface over LSP and Beam-specific extensions
- `skills`: installed Claude/Codex workflow guidance built around `lean-beam`
- Rocq support: a narrow auxiliary goal-probe surface through the same `lean-beam` wrapper, useful when porting from Rocq to Lean
- `tests`: scenario-DSL coverage for LSP-level behavior, concurrent stress coverage, broker and wrapper regression suites, and install/runtime validation

## Local Build And Test (for development)

Build:

```bash
lake build
```

Core tests:

```bash
bash tests/test.sh
```

Broker and wrapper suites:

```bash
bash tests/test-broker-fast.sh
bash tests/test-broker-slow.sh
bash tests/test-broker-rocq.sh
bash tests/test-broker.sh
bash scripts/lint-shell.sh
```

GitHub Actions currently validates the main CI job set from
[.github/workflows/ci.yml](.github/workflows/ci.yml) on both Ubuntu and macOS.

More detail on test coverage and gaps lives in [docs/TESTING.md](docs/TESTING.md).

## Documentation Map

- [docs/STATUS.md](docs/STATUS.md): current scope, limitations, and direction
- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md): Lean workflow contract
- [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md): auxiliary Rocq workflow surface
- [CONTRIBUTING.md](CONTRIBUTING.md): commit, PR, and contributor workflow guidance
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): AI-first maintainer workflow and harness guidance
- [docs/TESTING.md](docs/TESTING.md): test coverage and gaps
- [docs/experimental.md](docs/experimental.md): unstable experimental surfaces
- [AGENTS.md](AGENTS.md): repo-specific agent instructions

## License

Apache-2.0. See [LICENSE](LICENSE).
