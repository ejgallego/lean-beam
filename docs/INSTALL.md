# Installation

Run the installer from the repository root:

```bash
./scripts/install-beam.sh
```

With no flags, the installer is interactive. It asks which Lean toolchains, agent skills, and MCP
client registrations to set up, then shows the write locations and asks once whether to approve,
cancel, or change paths before writing. For scripts, pass `--dont-ask`; this skips prompts for
requested Beam-owned install/config paths but still refuses unrelated user files.

Each install rebuilds the runtime binaries from the current source checkout before staging the
immutable runtime. After reinstalling, restart active MCP client sessions so they launch the new
runtime instead of continuing to use an already-running server process.

## Default Locations

The default install creates:

- `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` in `$HOME/.local/bin`
- an immutable runtime under `BEAM_INSTALL_ROOT`, default `$HOME/.local/share/beam`
- a bundle cache under `$HOME/.local/share/beam/state/install-bundles`
- a prebuilt bundle for the repository-pinned supported Lean toolchain

| Purpose | Default | Override |
| --- | --- | --- |
| Command wrappers | `$HOME/.local/bin` | interactive `change`, or `BEAM_BIN_HOME` |
| Runtime root | `$HOME/.local/share/beam` | interactive `change`, or `BEAM_INSTALL_ROOT` |
| Install bundle cache | `$HOME/.local/share/beam/state/install-bundles` | derived from the runtime root |
| Source build output | `<repo>/.lake` | fixed by Lake for this checkout |
| Codex skill and MCP home | `$HOME/.codex` | interactive `change`, `CODEX_HOME`, or `--codex-home` |
| Codex MCP config | `$HOME/.codex/config.toml` | derived from the Codex home |
| Claude Code skill home | `$HOME/.claude` | interactive `change`, or `CLAUDE_HOME` |
| Claude Code MCP config | `$HOME/.claude.json` | interactive `change`, `BEAM_CLAUDE_MCP_CONFIG`, or `--claude-mcp-config` |

## Agent Skills

Install the bundled Lean skill for Codex, Claude Code, or both:

```bash
./scripts/install-beam.sh --codex
./scripts/install-beam.sh --claude
./scripts/install-beam.sh --all-skills
```

Install the optional Rocq skill by adding `--rocq-skill` to a selected agent target:

```bash
./scripts/install-beam.sh --codex --rocq-skill
./scripts/install-beam.sh --claude --rocq-skill
./scripts/install-beam.sh --all-skills --rocq-skill
```

`--rocq-skill` is only a modifier. It must be paired with `--codex`, `--claude`,
`--all-skills`, or an interactive skill target. Rocq-specific setup is documented in
[ROCQ.md](ROCQ.md).

## MCP Registration

Register the installed `lean-beam-mcp` server with Codex, Claude Code, or both:

```bash
./scripts/install-beam.sh --codex-mcp
./scripts/install-beam.sh --claude-mcp
./scripts/install-beam.sh --all-mcp
```

The installer can install skills and register MCP in one run:

```bash
./scripts/install-beam.sh --codex --codex-mcp
./scripts/install-beam.sh --claude --claude-mcp
./scripts/install-beam.sh --all-skills --all-mcp
```

For sandboxed config locations, pass the target paths explicitly:

```bash
./scripts/install-beam.sh --codex-mcp --codex-home /path/to/sandbox/.codex
./scripts/install-beam.sh --claude-mcp --claude-mcp-config /path/to/sandbox/.claude.json
```

The same overrides are available as `CODEX_HOME` and `BEAM_CLAUDE_MCP_CONFIG`.
Interactive installs that select MCP registration can also choose `change` at the write-location
prompt and edit the Codex home or Claude Code config path before approving writes.

To register an existing install manually, use an absolute path so the client can launch the server
even if `$HOME/.local/bin` is not on its `PATH`:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
claude mcp add --scope user lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
```

Codex selects `config.toml` from `CODEX_HOME`, and Claude Code's `mcp add` command selects the
user-scope config from `HOME`, so the installer runs those commands with the matching environment
set to the selected location.

MCP clients that support workspace roots can use the registered command as-is; Lean Beam discovers
the project root through `roots/list`. If a client does not provide roots, initialize one absolute
Lean/Lake project root per MCP server session with the `lean_init_workspace` tool before calling
Lean tools:

```json
{"root":"/path/to/lean/project"}
```

The normal call omits `mode`. Advanced clients can use `mode: "verify"` to check the active root or
`mode: "reset"` to explicitly switch roots and invalidate handles; see
[STATUS.md](STATUS.md#mcp-workspace-initialization).

Successful `lean_init_workspace` results include a `capabilities` array with projected MCP tool
names, including `beam_version`, `beam_stats`, `lean_run_at`, `lean_update`, `lean_sync`,
`lean_refresh`, `lean_save`, `lean_close_save`, `lean_hover`, `lean_signature_help`,
`lean_definition`, `lean_references`, `lean_document_symbols`, `lean_workspace_symbols`, and
`lean_goals`.

Direct MCP clients should call `lean_update` before snapshot-bound tools such as `lean_run_at`,
`lean_run_at_handle`, `lean_hover`, `lean_signature_help`, `lean_definition`,
`lean_references`, `lean_document_symbols`, `lean_goals`, and `lean_todo`; those calls require the
`version` returned by a successful `lean_update` or `lean_sync` for the same path. The
`lean_workspace_symbols` query is workspace-scoped and does not take a file version. `lean_goals`
also requires `mode: "before"` or `mode: "after"`. The `lean-beam` wrapper follows the same model:
call `lean-beam update <path>` first, then pass the returned `version` to `run-at`, `hover`,
`signature-help`, `definition`, `references`, `document-symbols`, `goals`, or `todo`. Use
`lean_sync` / `lean-beam sync` instead when the client also needs the diagnostics/readiness
barrier.

Direct developer runs and single-project MCP registrations may still pass an explicit project root:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp" --root /path/to/lean/project
claude mcp add --scope user lean-beam -- "$HOME/.local/bin/lean-beam-mcp" --root /path/to/lean/project
```

The `--root` startup flag accepts absolute paths and paths relative to the server's current working
directory. The `lean_init_workspace` tool intentionally accepts only absolute paths so clients do
not accidentally bind a session to a root interpreted from the server process cwd.

The wrapper resolves the matching installed `beam-cli`, Lean command, and Beam LSP plugin for each
project. Direct developer runs of `.lake/build/bin/lean-beam-mcp` may still pass `--lean-cmd` and
`--lean-plugin` explicitly.

Use `lean-beam --version` for bug reports and CLI refresh checks. It prints the public command
version, resolved wrapper path when launched through the wrapper, `beam-cli`, runtime payload hash,
manifest path, installed source commit when the manifest records one, and source checkout git
commit/branch/dirty state when no install manifest is present. Use `lean-beam doctor` when the
report also needs project-specific Lean/Lake bundle details.

Use `lean-beam-mcp --version` to check which MCP server command a client registration resolves.
The raw server executable reports the MCP server version, protocol revision, and server binary path;
the installed wrapper also prints the resolved wrapper path, server binary, `beam-cli`, runtime
payload hash, and manifest path, plus the installed source commit when the manifest records one.
Source checkout wrappers also include git commit/branch/dirty state when available. From a live MCP
session, call the `beam_version` tool to report the running server process identity as structured
content.
This is separate from `lean_init_workspace` with `mode: "reset"`, which restarts the Lean runtime
inside an already-running MCP server process but does not prove the MCP server binary itself
changed.

To verify the MCP path from a Lean project without writing JSON-RPC by hand, run:

```bash
lean-beam-mcp --root /path/to/lean/project --self-check MyPkg/Sub/Module.lean
```

The self-check starts a child MCP server, supplies the root through MCP `roots/list`, calls
`lean_sync` on the file, and shuts the child server down.

## Toolchains And Bundles

Use `--toolchain <toolchain>` or `--all-supported` to prebuild additional validated Lean bundles:

```bash
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.31.0
./scripts/install-beam.sh --all-supported
```

Lean Beam serves validated Lean toolchains listed in
[`supported-lean-toolchains`](../supported-lean-toolchains). Inspect the allowlist with:

```bash
lean-beam supported-toolchains
```

If you are working on Lean itself or another local Lean build through an elan-linked toolchain, use
`--custom-toolchain <toolchain>` to explicitly accept and prebuild that toolchain for this Beam
install:

```bash
elan toolchain link lean4-dev /path/to/lean/build/release/stage1
./scripts/install-beam.sh --custom-toolchain lean4-dev
```

Custom toolchains are not validated release targets. Beam records them in the installed runtime's
`custom-lean-toolchains` registry and serves only the exact custom names you installed. Bundle keys
also include the resolved Lean/Lake identity for that name, so relinking to a different local build
or changing the reported toolchain identity creates a different bundle instead of reusing stale
helpers. See [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the full custom toolchain and
runtime-bundle model.

If you are unsure which runtime bundle is active or why a toolchain is rejected, use:

```bash
lean-beam doctor
```

## Slow Or Offline Installs

On a cold machine, first bundle builds may need network access to fetch dependencies. When
travelling or working on a slow connection, install the supported Lean toolchains into the host
elan cache ahead of time:

```bash
grep -v '^[[:space:]]*#' supported-lean-toolchains | sed '/^[[:space:]]*$/d' |
  while IFS= read -r toolchain; do
    elan toolchain install "$toolchain"
  done
```

Maintainers running installer tests can then reuse that host cache and fail fast when a required
toolchain is missing:

```bash
BEAM_INSTALL_TEST_PRESEED_ELAN=require bash tests/test-beam-install.sh
```

Set `BEAM_INSTALL_TEST_PRESEED_ELAN=0` to force fully fresh fake homes, or leave it at the default
`auto` mode to opportunistically preseed when matching host toolchains exist.
