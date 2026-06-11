# Setup

Lean Beam setup has two separate locations:

- the Lean Beam checkout, where you run the installer once
- the Lean project you want to work on, where you run the installed `lean-beam` wrapper

You do not add Lean Beam to the target project's `lakefile`, and you do not install a copy into each
project. The wrapper detects the target project root from the current directory or `--root`.

## Install Beam From This Checkout

From a Lean Beam checkout, run one installer command that matches how you plan to use it:

```bash
./scripts/install-beam.sh           # CLI and MCP wrappers only
./scripts/install-beam.sh --codex   # wrappers plus Codex skills
./scripts/install-beam.sh --claude  # wrappers plus Claude Code skills
```

All three forms install:

- `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` into `~/.local/bin`
- an immutable runtime under `BEAM_INSTALL_ROOT`, default `~/.local/share/beam`
- a prebuilt bundle for the repo-pinned supported Lean toolchain

The agent flags also install the bundled Lean and Rocq skills into the corresponding agent home. Use
`--all-skills` when you want both Codex and Claude Code skills:

```bash
./scripts/install-beam.sh --all-skills
```

The installer requires `elan` on `PATH`. Make sure `~/.local/bin` is on `PATH` before using the
installed wrappers directly.

## Supported Toolchains And Bundles

Lean Beam only serves Lean toolchains listed in
[`supported-lean-toolchains`](../supported-lean-toolchains). Inspect the validated allowlist with:

```bash
lean-beam supported-toolchains
```

The current repo allowlist is:

```text
leanprover/lean4:v4.30.0
leanprover/lean4:v4.29.0
leanprover/lean4:v4.28.0
```

By default the installer prebuilds the Lean toolchain pinned by this repository. If your target
projects use other supported Lean releases, prebuild those bundles too:

```bash
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.29.0
./scripts/install-beam.sh --all-supported
```

If a supported target toolchain was not prebuilt, first use can still build a project-local fallback
bundle under that project's Beam state. On a cold machine, that fallback may need network access to
fetch dependencies.

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

Then start the per-project daemon and ask questions against saved files:

```bash
lean-beam ensure
lean-beam hover "Foo.lean" 10 2
lean-beam goals-prev "Foo.lean" 10 2
lean-beam run-at "Foo.lean" 10 2 "exact trivial"
```

Beam reads the saved file on disk, not unsaved editor buffers. After a real source edit, save the
file normally and then sync that workspace module before trusting later probes:

```bash
lean-beam sync "MyPkg/Sub/Module.lean"
```

For multiline speculative Lean text, pass the text on stdin:

```bash
printf '%s\n' 'example : True := by' '  trivial' | lean-beam run-at "Foo.lean" 10 2 --stdin
```

Read those commands like this:

- `lean-beam run-at` tries speculative Lean text without editing the file
- `lean-beam sync` is the explicit on-disk edit barrier after a real saved edit
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`
- `lean-beam save` checkpoints one synced workspace module; it does not validate downstream importers
- `lean-beam doctor` explains toolchain support and runtime bundle selection

Useful follow-up commands:

```bash
lean-beam deps "Foo.lean"
lean-beam refresh "MyPkg/Sub/Module.lean"
lean-beam save "MyPkg/Sub/Module.lean"
```

Detailed Lean workflow guidance lives in
[../skills/lean-beam/SKILL.md](../skills/lean-beam/SKILL.md). The narrower Rocq surface lives in
[../skills/rocq-beam/SKILL.md](../skills/rocq-beam/SKILL.md).

## MCP Setup

Use this section only when your editor or agent client speaks MCP. The ordinary `lean-beam` CLI
workflow does not require MCP.

The installer includes the experimental stdio MCP server as `lean-beam-mcp`. For Codex, register it
globally with an absolute path so Codex can launch it even if `~/.local/bin` is not on its PATH:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
```

MCP clients that support workspace roots can use that command as-is; Lean Beam discovers the project
root through `roots/list`. If a client does not provide roots, configure the command with an explicit
project root:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp" --root /path/to/lean/project
```

The wrapper resolves the matching installed `beam-cli`, Lean command, and runAt plugin for each
project. Direct developer runs of `.lake/build/bin/lean-beam-mcp` may still pass `--lean-cmd` and
`--lean-plugin` explicitly.

To verify the installed MCP path from a Lean project without writing JSON-RPC by hand, run:

```bash
lean-beam-mcp --root /path/to/lean/project --self-check MyPkg/Sub/Module.lean
```

The self-check starts a child MCP server, supplies the root through MCP `roots/list`, calls
`lean_sync` on the file, and shuts the child server down. Maintainer details for MCP live in the
[MCP maintainer notes](MCP.md).
