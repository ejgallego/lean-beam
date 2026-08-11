# Changelog

This project keeps a lightweight, reverse-chronological changelog. Dates use `YYYY-MM-DD`.

## Unreleased

0.2.0 beta development is open. Add user-facing changes here as they land.

### Added

- Canonical Lean RC and patch toolchains from declared compatible release lines can now build
  exact-fingerprint bundles that pass a local plugin qualification probe before use.
- Validated Lean `v4.33.0-rc2` support.
- Validated Lean `v4.32.0` support and made it the repository's default Lean toolchain
  ([#219](https://github.com/ejgallego/lean-beam/pull/219), @ejgallego).
- Mistral Vibe skill installation and MCP registration support through `--vibe`, `--vibe-mcp`,
  `--vibe-home`, and `VIBE_HOME`
  ([#213](https://github.com/ejgallego/lean-beam/pull/213), @archiebrowne).

### Changed

- The exact-validation registry and CLI command are now named `validated-lean-toolchains` and
  `validated-toolchains`; `--all-validated` prebuilds that finite exact matrix.
- `lean-beam open-files` now reports tracked-document state without performing partial Lake save
  preflight; `lean-beam save` remains the authoritative save eligibility check.

### Fixed

- `lean-save` and `lean-close-save` now reuse the accepted server snapshot for structured Lake
  `leanOptions`, dynamic libraries, and plugins. Modules with batch-only `moreLeanArgs` still fail
  with `saveUnsupportedSetup`, now with guidance to use `leanOptions` or `lake build`. Running Lean
  sessions must be restarted after Lake workspace configuration changes before syncing or saving.
- `lean-save` and `lean-close-save` now stage and commit complete artifact sets, preserving prior
  outputs on reported failure or cancellation and preventing same-worker saves from mixing files
  ([#217](https://github.com/ejgallego/lean-beam/pull/217), @ejgallego).
- `lean-save` and `lean-close-save` now invalidate prior Lake trace metadata before publishing
  artifacts and replace the new trace atomically, preventing prior metadata from describing newly
  published artifacts after a trace-write failure
  ([#218](https://github.com/ejgallego/lean-beam/pull/218), @ejgallego).
- Module-mode `lean-save` and `lean-close-save` now checkpoint the complete Lake artifact family,
  preventing replay from reusing stale `.olean.server`, `.olean.private`, or `.ir` files
  ([#214](https://github.com/ejgallego/lean-beam/pull/214), @ejgallego).
- Save-readiness decoding now rejects incomplete response envelopes instead of inferring that a
  document is ready to save
  ([#214](https://github.com/ejgallego/lean-beam/pull/214), @ejgallego).
- `lean-beam-mcp --self-check` now waits long enough for valid first-use local bundle builds and
  documents the `LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS` override
  ([#208](https://github.com/ejgallego/lean-beam/pull/208), @ejgallego).

### Documentation

- Clarify that zero-build saves are development checkpoints for the inner loop, make clean CI the
  preferred final batch validation, and use one clean local build when no clean CI result is
  available
  ([#216](https://github.com/ejgallego/lean-beam/pull/216), @ejgallego).
- Align the status page with the current broker protocol, which requires explicit `ok` / `error`
  response envelopes
  ([#216](https://github.com/ejgallego/lean-beam/pull/216), @ejgallego).

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
  [`validated-lean-toolchains`](validated-lean-toolchains); the repository-pinned default is
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
