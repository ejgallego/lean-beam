# Lean Beam

Lean Beam is an experimental Lean 4 tooling stack for querying saved Lean projects. It combines a
Lean LSP extension, a local broker, command-line wrappers, and optional MCP and agent-skill
integration.

It lets a client ask Lean questions about a saved source file at a particular line/character
position, then returns structured feedback such as hover and signature information, definitions,
references, symbols, goals, diagnostics, or the result of trying a small Lean fragment in the
surrounding module context.

Beam requests are tied to saved files on disk. Normal speculative requests do not edit the file, do
not mutate the document's real elaboration state, and do not create hidden state for later requests.
If a speculative result should become real source, edit the file, save it, and then update or sync
that file before later probes.

Feedback is welcome; feel free to open issues or let us know what you think on Zulip. For useful
bug reports from a local checkout, `lean-beam feedback --stdin` produces a pasteable Markdown report
card with Beam version, daemon registry, recent daemon incident, stats, and open-file context when
that data is available; see [Feedback Report Cards](docs/FEEDBACK.md).

Lean Beam is experimental public alpha software. It is not an official Lean FRO product. Current
scope, limitations, and release direction are tracked in [docs/STATUS.md](docs/STATUS.md).

## Why Lean Beam?

Lean already has Lake for builds and editor integrations for interactive development. Some workflows
also need many small, programmatic questions about local Lean state:

- What are the goals at this saved source position?
- Does this expression, command, or tactic elaborate here?
- Where is this symbol defined, and what references it?
- Which diagnostics are present after a saved edit?
- Can an external tool or agent get typed Lean feedback without owning a full editor session?

Lean Beam exists to make those questions explicit, local, and reusable across command-line, broker,
MCP, and agent-skill surfaces.

## Who Can It Help?

Lean Beam is mainly useful for:

- Lean users who want command-line checks against saved files.
- Tool authors building workflows on top of Lean LSP.
- Porting and proof-repair workflows that need many local Lean checks.
- Agent workflows, including Codex, Claude Code, Pi Agent, and OpenCode, that need a small typed
  Lean interaction surface.

Rocq support exists as a narrower auxiliary goal-inspection surface through the same installed
wrapper. It is useful for porting workflows, but it is not the main Lean Beam API.

## How It Works

Lean Beam is a thin layer over Lean LSP plus Beam-specific extensions.

- A Lean plugin adds speculative execution and related query primitives to Lean's LSP server.
- The Beam broker keeps one local runtime per project root and exposes a narrower local protocol.
- The `lean-beam` CLI wraps the broker for human and agent command-line workflows.
- The `lean-beam-mcp` server exposes the same Lean operations to MCP clients.
- Bundled skills describe the intended Lean and Rocq agent workflows.

The lower-level Lean protocol includes `$/lean/runAt`; the user-facing contract is simpler: ask Lean
a question at a saved file position, get typed feedback, and keep ordinary requests isolated.
Optional follow-up handles exist, but they are alpha extensions around that base request.

## Quick Setup

Install Beam once from a Lean Beam checkout:

```bash
./scripts/install-beam.sh
```

The default installer is interactive. It asks which supported Lean toolchains, agent skills, and MCP
client registrations to set up, then asks before writing Beam-owned install or config paths. For
non-interactive scripts, pass `--dont-ask`.

Use `--codex`, `--claude`, `--pi`, `--opencode`, or `--all-skills` when you also want bundled agent
skills. Then move to the Lean project you want to work on:

```bash
cd /path/to/lean/project
lean-beam doctor
lean-beam ensure
lean-beam update "Foo.lean"
version="<version-from-update>"
lean-beam hover "Foo.lean" "$version" 10 2
lean-beam definition "Foo.lean" "$version" 10 2
lean-beam goals before "Foo.lean" "$version" 10 2
lean-beam run-at "Foo.lean" "$version" 10 2 "exact trivial"
```

Beam reads saved files on disk, not unsaved editor buffers. After a real source edit, save the file
normally and update or sync that workspace module before trusting later probes:

```bash
lean-beam sync "MyPkg/Sub/Module.lean"
```

Detailed setup, supported toolchains, bundle behavior, and MCP client setup live in
[docs/SETUP.md](docs/SETUP.md). Detailed installer locations, overrides, and offline advice live in
[docs/INSTALL.md](docs/INSTALL.md).

## FAQ

### Does Lean Beam replace Lake?

No. Lake remains the build tool. Beam is for local interactive or programmatic queries against a
Lean project.

### Does Lean Beam replace an editor?

No. Beam reads saved files and exposes Lean queries. It does not manage unsaved editor buffers or
provide an IDE UI.

### Does a Beam probe edit my file?

No. Normal probes are speculative and isolated. To keep a result, make the real source edit yourself,
save the file, and run `lean-beam sync`.

### Which Lean versions are supported?

Lean Beam serves only the validated toolchains listed in
[`supported-lean-toolchains`](supported-lean-toolchains). Setup details are in
[docs/SETUP.md](docs/SETUP.md#supported-toolchains-and-bundles). Local Lean development builds can
also be accepted explicitly as custom toolchains; see
[docs/CUSTOM_TOOLCHAINS.md](docs/CUSTOM_TOOLCHAINS.md).

### Is Lean Beam an official Lean product?

No. Lean Beam is a public experimental project, not an official Lean FRO product.

### Is Lean Beam stable?

No. Lean Beam is alpha software and uses internal Lean APIs. Expect the public surface to remain
small while installation, stale-state handling, and protocol details continue to mature.

## Documentation Map

For users:

- [docs/SETUP.md](docs/SETUP.md): install, toolchain, bundle, and MCP setup details.
- [docs/INSTALL.md](docs/INSTALL.md): detailed installer locations, overrides, and offline advice.
- [docs/CUSTOM_TOOLCHAINS.md](docs/CUSTOM_TOOLCHAINS.md): explicit local Lean toolchain support.
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): alpha compatibility policy and supported targets.
- [docs/ROCQ.md](docs/ROCQ.md): optional Rocq goal probes for Rocq-to-Lean porting.
- [docs/STATUS.md](docs/STATUS.md): current scope, limitations, and direction.
- [CHANGELOG.md](CHANGELOG.md): release-facing changes.

For agent workflows:

- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md): Lean workflow contract.
- [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md): auxiliary Rocq workflow surface.

For contributors and maintainers:

- [CONTRIBUTING.md](CONTRIBUTING.md): commit, PR, and contributor workflow guidance.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): maintainer workflow and implementation notes.
- [docs/TESTING.md](docs/TESTING.md): developer test-suite guidance and coverage map.
- [docs/SYNC_AND_DIAGNOSTICS.md](docs/SYNC_AND_DIAGNOSTICS.md): sync, save, progress,
  diagnostics, and readiness contract.
- [docs/MCP.md](docs/MCP.md): current MCP architecture and conformance notes.
- [AGENTS.md](AGENTS.md): repo-specific agent instructions.

## Contributing And Help

Bug reports, design feedback, and documentation improvements are welcome through
[GitHub issues](https://github.com/ejgallego/lean-beam/issues). Discussion is also welcome on the
[Lean Zulip](https://leanprover.zulipchat.com).

Before contributing code or docs, read [CONTRIBUTING.md](CONTRIBUTING.md). Maintainer workflow notes
live in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
