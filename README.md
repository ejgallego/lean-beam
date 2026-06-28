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

The default installer is interactive. It asks which Lean toolchains, agent skills, and MCP client
registrations to set up, then shows write locations and lets you approve, cancel, or change paths.
Common setup commands:

```bash
./scripts/install-beam.sh --codex --codex-mcp
./scripts/install-beam.sh --claude --claude-mcp
./scripts/install-beam.sh --all-skills --all-mcp
```

The installer puts `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` in `$HOME/.local/bin`,
stages an immutable runtime under `BEAM_INSTALL_ROOT` (default `$HOME/.local/share/beam`), and
prebuilds a bundle for the repository-pinned supported Lean toolchain.

See [docs/INSTALL.md](docs/INSTALL.md) for default locations, path overrides, sandboxed Codex and
Claude Code config setup, supported/custom toolchains, and slow/offline install advice.

## MCP Setup

The installer includes the experimental stdio MCP server as `lean-beam-mcp`. Register it with Codex,
Claude Code, or both through the installer:

```bash
./scripts/install-beam.sh --codex-mcp
./scripts/install-beam.sh --claude-mcp
./scripts/install-beam.sh --all-mcp
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

MCP clients can opt into live operation progress for `tools/call` requests by including
`params._meta.progressToken` as a string or integer. The field-level progress, diagnostic, and
sync-summary contract is maintained in
[docs/SYNC_AND_DIAGNOSTICS.md](docs/SYNC_AND_DIAGNOSTICS.md).
Registration, sandboxed config paths, manual registration, explicit roots, and self-check details
are in [docs/INSTALL.md](docs/INSTALL.md#mcp-registration).

## Supported Toolchains

Lean Beam serves validated Lean toolchains listed in
[`supported-lean-toolchains`](supported-lean-toolchains). It can also serve explicit custom
toolchains recorded at install time with `--custom-toolchain`; this is intended for local Lean
development toolchains and does not make those toolchains validated release targets. Runtime bundle
identity and custom-toolchain rules are documented in [docs/INSTALL.md](docs/INSTALL.md) and
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
- `lean-beam deps` reports the broker's direct workspace dependency view for a path; it is a
  scanner-backed triage helper, not an authoritative Lake build-graph query
- `lean-beam sync` is the explicit on-disk edit barrier after a real saved edit
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`
- `lean-beam save` checkpoints one synced workspace module; it does not validate downstream importers
- `lean-beam save` currently supports only Lake module setups that Beam can replay from the LSP
  snapshot without custom batch setup; modules with custom Lean options, Lean arguments, dynamic
  libraries, or plugins fail with `saveUnsupportedSetup` and should be rebuilt with `lake build`

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
diagnostics streamed on stderr for that request. `lean-beam save` includes its sync verdict in
`result.sync`; `lean-beam close-save` includes it in `result.saved.sync`; document-error save
failures include the blocking verdict in `error.data.sync`. See
[docs/SYNC_AND_DIAGNOSTICS.md](docs/SYNC_AND_DIAGNOSTICS.md) for the exact progress, diagnostic,
and readiness fields.

When `lean-beam sync` fails with `syncBarrierIncomplete`, the JSON error may include
`error.data.staleDirectDeps`, `error.data.saveDeps`, and `error.data.recoveryPlan` to suggest a
cheap direct-import recovery path before falling back to `lake build`. It may also include
`error.data.completionBlockingDiagnostics`; those entries carry `completionBlocking=true` because
the file could not reach the diagnostics-complete barrier for that version.

When `lean-beam save` fails with `saveUnsupportedSetup`, the synced file may still be clean. The
failure means Beam refused to write a zero-build Lake artifact for a module whose Lake batch setup is
not known to be equivalent to the LSP snapshot. Use `lake build` for that module or its importer.

Detailed Lean workflow guidance lives in [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md).

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
- `tests`: scenario-DSL coverage for LSP-level behavior, concurrent stress coverage, broker and wrapper regression suites, and install/runtime validation

## Local Build And Test (for development)

Build:

```bash
lake build
```

LSP surface:

```bash
bash tests/test-lsp.sh
```

Beam surface:

```bash
bash tests/test-beam-fast.sh
bash tests/test-beam-slow.sh
bash tests/test-beam.sh
bash tests/test-beam-toolchain-compat.sh leanprover/lean4:v4.29.0
bash tests/test-beam-rocq.sh
bash scripts/lint-shell.sh
```

The preferred organization is `LSP` vs `Beam`. Maintainer-only checks live in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and [docs/TESTING.md](docs/TESTING.md).

GitHub Actions currently validates the main CI job set from
[.github/workflows/ci.yml](.github/workflows/ci.yml) on both Ubuntu and macOS.

More detail on test coverage and gaps lives in [docs/TESTING.md](docs/TESTING.md).

## Documentation Map

- [docs/STATUS.md](docs/STATUS.md): current scope, limitations, and direction
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): alpha compatibility policy and supported targets
- [docs/SYNC_AND_DIAGNOSTICS.md](docs/SYNC_AND_DIAGNOSTICS.md): sync, save,
  diagnostics, progress, and readiness reporting contract
- [docs/ROCQ.md](docs/ROCQ.md): optional Rocq Beam goal probes for Rocq-to-Lean porting
- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md): Lean workflow contract
- [CONTRIBUTING.md](CONTRIBUTING.md): commit, PR, and contributor workflow guidance
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): AI-first maintainer workflow and harness guidance
- [docs/TESTING.md](docs/TESTING.md): testing surfaces, coverage, and gaps
- [docs/experimental.md](docs/experimental.md): unstable experimental surfaces
- [AGENTS.md](AGENTS.md): repo-specific agent instructions

## License

Apache-2.0. See [LICENSE](LICENSE).
