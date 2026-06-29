# LSP Coverage Registry

This directory contains metadata for the LSP surface tested by `tests/test-lsp.sh`.

- `methods.json` lists each Beam or Lean LSP method registered by `Beam/LSP/Plugin.lean`,
  where the method name is defined, and the coverage tags required for that method.
- `cases.json` maps concrete tests to methods and coverage tags. Each case pointer should name
  the smallest useful test artifact, such as a scenario file, an interactive Lean input, or a
  request-family Lean helper under `tests/lean/BeamTest/LSP/Requests`.
- `check.py` verifies that registered methods, required coverage tags, method definitions, and
  case pointers stay synchronized.

Keep this registry as metadata only. Executable behavior should remain in the Lean, scenario, and
interactive test harnesses.
