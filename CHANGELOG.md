# Changelog

This project keeps a lightweight, reverse-chronological changelog. Dates use `YYYY-MM-DD`.

## Unreleased

0.2.0 beta development is open. Add user-facing changes here as they land.

### Added

- Mistral Vibe skill installation and MCP registration support through `--vibe`, `--vibe-mcp`,
  `--vibe-home`, and `VIBE_HOME`
  ([#213](https://github.com/ejgallego/lean-beam/pull/213), @archiebrowne).

### Fixed

- `lean-save` and `lean-close-save` now stage and commit complete artifact sets, preserving prior
  outputs on reported failure or cancellation and preventing same-worker saves from mixing files.
- Module-mode `lean-save` and `lean-close-save` now checkpoint the complete Lake artifact family,
  preventing replay from reusing stale `.olean.server`, `.olean.private`, or `.ir` files.
- Save-readiness decoding now rejects incomplete response envelopes instead of inferring that a
  document is ready to save.
- `lean-beam-mcp --self-check` now waits long enough for valid first-use local bundle builds and
  documents the `LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS` override.

## 0.1.0 - 2026-07-07

Initial public release.

### Added

- Isolated `$/lean/runAt` execution with internal proof-first, command-fallback basis selection.
- Minimal typed request and response surface for speculative Lean probes.
- Optional follow-up handles through `$/lean/runWith` and `$/lean/releaseHandle`.
- Version-bound `lean-beam update`, `sync`, `save`, and `close-save` workflows.
- Semantic navigation wrappers for hover, signature help, definitions, references, symbols, goals,
  and todo-style actionable items.
- Local Beam broker/client and `lean-beam` wrapper for saved-file Lean workflows.
- Experimental `lean-beam-mcp` stdio server over the shared Beam operation layer.
- Installed skills for supported agent clients and an optional Rocq goal-probe surface.
- Runtime identity and diagnostic surfaces such as `lean-beam --version`, `beam_version`,
  `open-files`, and broker stats.
- Feedback report cards through `lean-beam feedback` and MCP `beam_feedback`.

### Compatibility And Reliability

- Validated Lean toolchains are listed in
  [`supported-lean-toolchains`](supported-lean-toolchains); the repository-pinned default is
  recorded in [`lean-toolchain`](lean-toolchain).
- Repo-local and CI coverage exercise isolation, stale edits, cancellation, invalid positions,
  handle invalidation, sync/save readiness, MCP protocol behavior, installer behavior, and supported
  Lean toolchain compatibility.

### Documentation

- Human-facing [README](README.md), [setup](docs/SETUP.md), [compatibility](docs/COMPATIBILITY.md),
  [status](docs/STATUS.md), [testing](docs/TESTING.md), [MCP](docs/MCP.md), and
  [skill workflow](skills/lean-beam/SKILL.md) docs for the public alpha surface.
- Conservative release posture: keep the public API small, document known limitations, and defer
  broader dependency/readiness redesigns until Lean or Lake expose stronger primitives.
