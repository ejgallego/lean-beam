# Lean Beam

Lean Beam lets humans and agents ask Lean one question at a saved source position without editing
the file or rebuilding the project.

The smallest request is `runAt(pos, "lean text")`: try this Lean text here, in the real module
context, and return typed Lean feedback. Ordinary calls are isolated. They do not mutate the source
file, and they do not become hidden state for the next request. If a speculative result should become
real source, edit the file, save it, then run `lean-beam sync`.

That makes Beam useful for proof repair, porting, proof-search experiments, and agent workflows that
need many small Lean checks inside a real project. Optional handles support exact continuation from a
speculative state, but the base story stays one saved file, one position, one Lean text payload.

Lean Beam is not a replacement for Lake or for an IDE. It is a local layer over Lean LSP plus
Beam-specific extensions: a Lean plugin provides the execution primitive, and the Beam CLI, broker,
MCP server, and bundled skills project that primitive into practical workflows.

Lean Beam started as a personal internal project and is now published for public use. It is not an
official Lean FRO product, the code remains experimental, and you should use it at your own risk.

Feedback is welcome through
[GitHub issues](https://github.com/ejgallego/lean-beam/issues) or the
[Lean Zulip](https://leanprover.zulipchat.com).

## Quick Setup

Install Beam once from a Lean Beam checkout:

```bash
./scripts/install-beam.sh
```

Use `--codex`, `--claude`, or `--all-skills` when you also want the bundled agent skills. Then move
to the Lean project you want to work on:

```bash
cd /path/to/lean/project
lean-beam doctor
lean-beam ensure
lean-beam run-at "Foo.lean" 10 2 "exact trivial"
```

Beam reads saved files on disk, not unsaved editor buffers. After a real source edit, save the file
normally and sync that workspace module before trusting later probes:

```bash
lean-beam sync "MyPkg/Sub/Module.lean"
```

Detailed setup, supported toolchains, bundle behavior, and MCP client setup live in
[docs/SETUP.md](docs/SETUP.md). Lean workflow guidance lives in
[skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md); the narrower Rocq surface lives in
[skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md).

## Which Layer To Use

- Use `lean-beam` if you want the practical CLI workflow for humans, Codex, or Claude.
- Use `lean-beam-mcp` if your agent client wants MCP tools instead of shell commands.
- Use the Beam broker if you want one long-lived local process per project root while keeping a
  narrower local protocol than raw LSP.
- Use the Lean LSP extension directly if you already own the LSP session and want the smallest
  typed surface, or if you are building custom agents doing MCTS or other advanced setups.

The public request and response types live in [RunAt/Protocol.lean](RunAt/Protocol.lean). The
Lean plugin implementation lives in [RunAt/Plugin.lean](RunAt/Plugin.lean).

## Contributing

Contributor workflow, local harness guidance, and test details are intentionally outside the
user path:

- [CONTRIBUTING.md](CONTRIBUTING.md): commit, PR, and contributor workflow guidance.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): maintainer workflow and implementation notes.
- [docs/TESTING.md](docs/TESTING.md): developer test-suite guidance and coverage map.

## Documentation Map

For users:

- [docs/SETUP.md](docs/SETUP.md): install, toolchain, bundle, and MCP setup details.
- [docs/STATUS.md](docs/STATUS.md): current scope, limitations, and direction.
- [docs/experimental.md](docs/experimental.md): unstable experimental surfaces.

For agent workflows:

- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md): Lean workflow contract.
- [skills/rocq-beam/SKILL.md](skills/rocq-beam/SKILL.md): auxiliary Rocq workflow surface.

For contributors and maintainers:

- [CONTRIBUTING.md](CONTRIBUTING.md): commit, PR, and contributor workflow guidance.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): maintainer workflow and implementation notes.
- [docs/TESTING.md](docs/TESTING.md): developer test-suite guidance and coverage map.
- [docs/MCP.md](docs/MCP.md): current MCP architecture and conformance notes.
- [AGENTS.md](AGENTS.md): repo-specific agent instructions.
- [docs/archive/MCP_PLAN.md](docs/archive/MCP_PLAN.md): historical MCP design note.

## License

Apache-2.0. See [LICENSE](LICENSE).
