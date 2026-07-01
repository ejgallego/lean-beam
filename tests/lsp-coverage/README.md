# LSP Coverage Registry

This directory contains metadata for the LSP surface tested by `tests/test-lsp.sh`.

- `methods.json` lists each Beam or Lean LSP method registered by `Beam/LSP/Plugin.lean`,
  where the method name is defined, the request family, and the coverage tags required for that
  method.
- `cases.json` maps concrete tests to methods and coverage tags. Each case pointer should name
  the smallest useful test artifact, such as a scenario file, an interactive Lean input, or a
  request-family Lean helper under `tests/lean/BeamTest/LSP/Requests`. Coverage tags must be
  declared by the matching method in `methods.json`.
- `check.py` verifies that registered methods, required coverage tags, method definitions, and
  case pointers stay synchronized.

Keep this registry as metadata only. Executable behavior should remain in the Lean, scenario, and
interactive test harnesses.

## Pointer Guidance

Prefer pointers that identify the smallest artifact responsible for the behavior:

- use request-family Lean helpers under `tests/lean/BeamTest/LSP/Requests` for method-local
  behavior, including stale versions, invalid positions, standard LSP interference, and
  request-specific response shape checks
- use `tests/scenario` files when the behavior depends on the upstream scenario runner DSL,
  pending-request choreography, cancellation, or multi-step edit timing
- use `tests/interactive` files when the behavior is a file-anchored golden test for position
  selection, proof-vs-command basis selection, or historical interactive input shape
- use handle tests under `tests/lean/BeamTest/LSP/Handle` when the behavior depends on stored
  follow-up handles rather than the base `runAt` request

Add a tag to `methods.json` only when a missing case for that tag would make the method look
under-tested. Incidental behavior may still be asserted in executable tests without becoming a
required registry tag. Common robustness tags include `invalid-position`, `stale-version`,
`stale-edit`, `stale-hash`, `cancellation`, `mixed-concurrency`, and
`standard-lsp-interference`.
