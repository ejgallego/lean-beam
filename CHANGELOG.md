# Changelog

This project keeps a lightweight, reverse-chronological changelog. Dates use `YYYY-MM-DD`.
Until the first tagged release, release-facing changes stay under `Unreleased`.

## Unreleased

Preparing the first public Lean Beam alpha release.

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

### Testing

- Repo-local coverage for isolation, stale edits, cancellation, invalid positions, handle
  invalidation, sync/save readiness, MCP protocol behavior, installer behavior, and supported Lean
  toolchain compatibility.

### Documentation

- Human-facing [README](README.md), [setup](docs/SETUP.md), [compatibility](docs/COMPATIBILITY.md),
  [status](docs/STATUS.md), [testing](docs/TESTING.md), [MCP](docs/MCP.md), and
  [skill workflow](skills/lean-beam/SKILL.md) docs for the public alpha surface.
- Conservative release posture: keep the public API small, document known limitations, and defer
  broader dependency/readiness redesigns until Lean or Lake expose stronger primitives.
