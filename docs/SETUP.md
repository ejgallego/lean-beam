# Setup

Use this document as the single path from a Lean Beam checkout to a working `lean-beam` command.
It covers installation, supported Lean toolchains, first CLI use, MCP registration, installer
locations, and offline setup notes.

Lean Beam setup has two separate locations:

- the Lean Beam checkout, where you run the installer once
- the Lean project you want to work on, where you run the installed `lean-beam` wrapper

You do not add Lean Beam to the target project's `lakefile`, and you do not install a copy into each
project. The wrapper detects the target project root from the current directory or `--root`.

## Install Beam From This Checkout

From a Lean Beam checkout, run one installer command that matches how you plan to use it:

```bash
./scripts/install-beam.sh            # CLI and MCP wrappers only
./scripts/install-beam.sh --codex    # wrappers plus Codex skills
./scripts/install-beam.sh --claude   # wrappers plus Claude Code skills
./scripts/install-beam.sh --pi       # wrappers plus Pi Agent skills
./scripts/install-beam.sh --opencode # wrappers plus OpenCode skills
./scripts/install-beam.sh --all-skills # wrappers plus every supported agent skill
```

The default installer is interactive: it asks which supported Lean toolchains, agent skills, and
MCP client registrations to set up. It then shows a compact write summary and asks once for the Beam
runtime/wrapper install area, selected skill locations, and selected MCP config locations. For
non-interactive scripts, pass `--dont-ask`; this only skips prompts for requested Beam-owned
install/config paths and does not allow replacing unrelated user files.

These forms install:

- `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` into `~/.local/bin`
- an immutable runtime under `BEAM_INSTALL_ROOT`, default `~/.local/share/beam`
- a bundle cache under `~/.local/share/beam/state/install-bundles`
- a prebuilt bundle for the repo-pinned supported Lean toolchain

Each install rebuilds the runtime binaries from the current source checkout before staging the
immutable runtime. After reinstalling, restart active MCP client sessions so they launch the new
runtime instead of continuing to use an already-running server process.

The agent flags install the bundled Lean skill into the corresponding agent home. Rocq support is a
separate optional skill; add `--rocq-skill` to a selected agent target when you also want the Rocq
skill:

```bash
./scripts/install-beam.sh --codex --rocq-skill
./scripts/install-beam.sh --all-skills --rocq-skill
```

`--rocq-skill` is only a modifier. It must be paired with `--codex`, `--claude`, `--pi`,
`--opencode`, `--all-skills`, or an interactive skill target. Rocq-specific setup is documented in
[ROCQ.md](ROCQ.md).

The installer requires `elan` on `PATH`. Make sure `~/.local/bin` is on `PATH` before using the
installed wrappers directly.

## Supported Toolchains And Bundles

Lean Beam serves validated Lean toolchains listed in
[`supported-lean-toolchains`](../supported-lean-toolchains). Check that file before install if you
need a specific Lean release. After install, the wrapper reports the same validated allowlist with:

```bash
lean-beam supported-toolchains
```

The repository's [`lean-toolchain`](../lean-toolchain) is the default toolchain prebuilt by the
installer. The allowlist may include adjacent Lean releases for compatibility testing; the file
above and `lean-beam supported-toolchains` are the source of truth. If your target projects use
other supported Lean releases, prebuild those bundles too:

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

Custom toolchains are not validated release targets. Beam records exact custom names in the
installed runtime's `custom-lean-toolchains` registry and includes the resolved Lean/Lake identity
in bundle keys, so relinking a local toolchain creates a different bundle rather than reusing stale
helpers. See [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the full model.

If a supported or explicitly custom target toolchain was not prebuilt, first use can still build a
project-local fallback bundle under that project's Beam state. On a cold machine, that fallback may
need network access to fetch dependencies.

If you are unsure which runtime bundle is active or why a toolchain is rejected, use:

```bash
lean-beam doctor
```

## Use Beam From A Lean Project

Move to the Lean project you want to work on and check the resolved setup:

```bash
cd /path/to/lean/project
lean-beam doctor
```

Command positions use Lean/LSP coordinates: line and character are zero-based, and character counts
UTF-16 code units.

Then start the per-project daemon and ask questions against a saved Lean file in that project:

```bash
lean-beam ensure
update_json="$(lean-beam update "Foo.lean")"
printf '%s\n' "$update_json"
version="$(printf '%s\n' "$update_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["version"])')"
lean-beam hover "Foo.lean" "$version" 10 2
lean-beam definition "Foo.lean" "$version" 10 2
lean-beam goals before "Foo.lean" "$version" 10 2
lean-beam run-at "Foo.lean" "$version" 10 2 "exact trivial"
```

The `python3` line extracts `result.version` for shell examples. You can also copy that version
number from the printed `lean-beam update` JSON.

Beam reads the saved file on disk, not unsaved editor buffers. After a real source edit, save the
file normally and then update or sync that workspace module before trusting later probes:

```bash
lean-beam update "MyPkg/Sub/Module.lean"
lean-beam sync "MyPkg/Sub/Module.lean"
```

For multiline speculative Lean text, pass the text on stdin:

```bash
printf '%s\n' 'example : True := by' '  trivial' |
  lean-beam run-at "Foo.lean" "$version" 10 2 --stdin
```

Read those commands like this:

- `lean-beam update` opens or updates the broker's LSP mirror and returns the current document
  version without waiting for diagnostics
- `lean-beam run-at` tries speculative Lean text without editing the file
- `lean-beam sync` waits for diagnostics/readiness after a real saved edit
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`
- `lean-beam save` checkpoints one synced workspace module; it does not validate downstream importers
- `lean-beam doctor` explains toolchain support and runtime bundle selection

Position and range probes are version-bound. Use the `version` returned by `lean-beam update` or
`lean-beam sync` for `run-at`, `hover`, `signature-help`, `definition`, `references`,
`document-symbols`, `goals`, and `todo`. Workspace symbol queries are workspace-scoped and do not
take a file version. If Beam reports `contentModified`, update or sync the file again and retry
with the accepted current version rather than guessing.

Useful follow-up commands:

```bash
lean-beam open-files
lean-beam refresh "MyPkg/Sub/Module.lean"
lean-beam save "MyPkg/Sub/Module.lean"
```

Detailed Lean workflow guidance lives in
[../skills/lean-beam/SKILL.md](../skills/lean-beam/SKILL.md). The narrower Rocq surface is
summarized in [ROCQ.md](ROCQ.md), with agent workflow details in
[../skills/rocq-beam/SKILL.md](../skills/rocq-beam/SKILL.md).

## MCP Setup

Use this section only when your editor or agent client speaks MCP. The ordinary `lean-beam` CLI
workflow does not require MCP.

The installer includes the experimental stdio MCP server as `lean-beam-mcp`. It can register the
server automatically for Codex, Claude Code, or OpenCode. For OpenCode, the installer prints the
`opencode mcp add` values to use manually. Pi Agent does not support MCP; install its skill with
`--pi`.

```bash
./scripts/install-beam.sh --codex-mcp
./scripts/install-beam.sh --claude-mcp
./scripts/install-beam.sh --opencode-mcp
./scripts/install-beam.sh --all-mcp
```

To register an existing install manually, use an absolute path so the client can launch the server
even if `~/.local/bin` is not on its PATH:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
claude mcp add --scope user lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
opencode mcp add
```

When `opencode mcp add` prompts for the server, use:

```text
name: lean-beam
type: local
command: /absolute/path/to/lean-beam-mcp
```

MCP clients that support workspace roots can use that command as-is; Lean Beam discovers the project
root through `roots/list`. If a client does not provide roots, initialize one absolute Lean/Lake
project root per MCP server session with the `lean_init_workspace` tool before calling Lean tools:

```json
{"root":"/path/to/lean/project"}
```

The normal call omits `mode`. Advanced clients can use `mode: "verify"` to check the active root or
`mode: "reset"` to explicitly switch roots and invalidate handles; see
[the MCP runtime setup notes](MCP.md#runtime-setup). Direct-client tool and version semantics live
in the [MCP protocol notes](MCP.md#client-tool-semantics).

Direct single-project MCP registrations may still pass an explicit project root:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp" --root /path/to/lean/project
claude mcp add --scope user lean-beam -- "$HOME/.local/bin/lean-beam-mcp" --root /path/to/lean/project
```

The `--root` startup flag accepts absolute paths and paths relative to the server's current working
directory. The `lean_init_workspace` tool intentionally accepts only absolute paths so clients do
not accidentally bind a session to a root interpreted from the server process cwd.

The wrapper resolves the matching installed Beam runtime for each project.

Use `lean-beam --version` for bug reports and CLI refresh checks. Use `lean-beam-mcp --version` to
check which MCP server command a client registration resolves. From a live MCP session, call the
`beam_version` tool to report the running server process identity as structured content.

Use `lean-beam feedback --stdin` when reporting setup or runtime issues; see
[FEEDBACK.md](FEEDBACK.md).

To verify the installed MCP path from a Lean project without writing JSON-RPC by hand, run:

```bash
lean-beam-mcp --root /path/to/lean/project --self-check MyPkg/Sub/Module.lean
```

The self-check starts a child MCP server, supplies the root through MCP `roots/list`, calls
`lean_sync` on the file, and shuts the child server down. Maintainer details for MCP live in the
[MCP maintainer notes](MCP.md).

## Installer Locations And Overrides

Default install locations are:

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
| Pi Agent skill home | `$HOME/.pi/agent` | interactive `change`, `PI_CODING_AGENT_DIR`, or `--pi-home` |
| OpenCode config directory | `$HOME/.config/opencode` | interactive `change`, `OPENCODE_CONFIG_DIR`, or `--opencode-config-dir` |
| OpenCode skill home | `$HOME/.config/opencode/skills` | derived from the OpenCode config directory |

For sandboxed config locations, pass the target paths explicitly:

```bash
./scripts/install-beam.sh --codex-mcp --codex-home /path/to/sandbox/.codex
./scripts/install-beam.sh --claude-mcp --claude-mcp-config /path/to/sandbox/.claude.json
```

The same Codex and Claude overrides are available as `CODEX_HOME` and
`BEAM_CLAUDE_MCP_CONFIG`. Interactive installs can also choose `change` at the write-location
prompt before approving writes.

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

Then run the installer with `--toolchain <toolchain>` for the target releases you need, or
`--all-supported` for the full validated allowlist.
