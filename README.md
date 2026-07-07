# Lean Beam

Lean Beam is an experimental project for efficient interaction with Lean from AI-assisted and
tool-assisted workflows. Its main pieces are new Lean LSP extensions, a `lean-beam` CLI, and a
`lean-beam-mcp` server, connected by a lightweight broker that provides a convenient agent- and
tool-facing interface.

Beam lets a client try Lean commands or tactics at specific positions in saved files without
changing those files. The central Beam extension is speculative execution through `runAt`, exposed
by the CLI as `lean-beam run-at` and through MCP as `lean_run_at`. Because these probes can be
issued concurrently, agents and tools can cheaply explore several "would this work here?"
possibilities in the real module context.

Together, the LSP extensions, CLI, and MCP interface are intended to make that loop cheaper and more
structured than repeatedly creating scratch files or using full `lake build` runs as the inner loop.

Beam is implemented in Lean, which lets it integrate more directly with Lean server state, saved
snapshots, and synchronization where that matters.

We have found Beam useful for proof repair, proof search experiments, proof translation and porting,
autoformalization experiments, and regular AI-assisted Lean editing.

Feedback is welcome; feel free to open issues or let us know what you think on Zulip. For useful bug
reports from a local checkout, `lean-beam feedback --stdin` can produce a pasteable report card; see
[docs/FEEDBACK.md](docs/FEEDBACK.md).

Lean Beam is experimental public alpha software. It is not an official Lean FRO product. Current
scope, limitations, and release direction are tracked in [docs/STATUS.md](docs/STATUS.md).

## Current Alpha Surface

The current release includes support for:

- speculative Lean execution with `runAt`
- incremental synchronization of Lean's view of a file after edits with `sync`
- actionable file information with `todo`, including sorries, holes, diagnostics, code actions, and
  incomplete proofs
- saving `.olean` artifacts from an interactive session with `save`
- selected Lean/LSP features through the same CLI and MCP interfaces, including hover, signature
  help, definitions, references, document/workspace symbols, and proof-state inspection
- feedback report cards for bug reports and project feedback through `lean-beam feedback` and MCP
  `beam_feedback`

See the repository documentation for the current supported surface, which we expect to evolve during
the alpha.

## Install

Install or update Beam from a Lean Beam checkout:

```bash
./scripts/install-beam.sh
```

Run the installer again when you update the checkout and want the installed runtime to match it.
Setup details, supported toolchains, agent-skill installation, MCP registration, and direct CLI
examples live in [docs/SETUP.md](docs/SETUP.md). Detailed installer locations, overrides, and
offline advice live in [docs/INSTALL.md](docs/INSTALL.md).

Lean Beam serves validated Lean toolchains listed in
[`supported-lean-toolchains`](supported-lean-toolchains). See
[docs/SETUP.md](docs/SETUP.md#supported-toolchains-and-bundles) for bundle setup and
[docs/CUSTOM_TOOLCHAINS.md](docs/CUSTOM_TOOLCHAINS.md) for explicitly accepted local Lean builds.

## Documentation Map

For users:

- [docs/SETUP.md](docs/SETUP.md): install, toolchain, bundle, and MCP setup details.
- [docs/INSTALL.md](docs/INSTALL.md): detailed installer locations, overrides, and offline advice.
- [docs/CUSTOM_TOOLCHAINS.md](docs/CUSTOM_TOOLCHAINS.md): explicit local Lean toolchain support.
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): alpha compatibility policy and supported targets.
- [docs/ROCQ.md](docs/ROCQ.md): optional Rocq goal probes for Rocq-to-Lean porting.
- [docs/FEEDBACK.md](docs/FEEDBACK.md): feedback report cards for useful bug reports.
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

The main goal of this public alpha is to gather feedback from Lean users and tool authors.
Bug reports, design feedback, and documentation improvements are welcome through
[GitHub issues](https://github.com/ejgallego/lean-beam/issues). Discussion is also welcome on the
[Lean Zulip](https://leanprover.zulipchat.com).

Before contributing code or docs, read [CONTRIBUTING.md](CONTRIBUTING.md). Maintainer workflow notes
live in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
