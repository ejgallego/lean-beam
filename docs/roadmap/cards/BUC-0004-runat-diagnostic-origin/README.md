# BUC-0004 runAt Diagnostic Origin Mapping

Status: candidate-0.2.0
Kind: diagnostics
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07

## Summary

Multiline `runAt` diagnostics currently point into a synthetic `<runAt>` file,
for example `<runAt>:56:4`, without returning structured ranges in the
submitted text. MCP callers often do not have a durable copy of the generated
snippet, so agents must reconstruct line numbers by hand.

## Impact

- Agents cannot reliably map Lean diagnostics back to the speculative text they
  submitted.
- Long snippets make `<runAt>` line numbers expensive and error-prone to
  interpret.
- Useful diagnostics become harder to paste into a precise bug report.

## Beam Decision

Keep this in 0.2.0 scope if it can be implemented without broadening the public
request. It improves the existing `runAt` result rather than adding a new
workflow surface.

## Expected Behavior

Diagnostics from synthetic buffers should include origin metadata:

```json
{
  "origin": "runAtText",
  "rangeInSubmittedText": {
    "start": {"line": 55, "character": 4},
    "end": {"line": 55, "character": 10}
  },
  "submittedTextHash": "sha256:...",
  "submittedLine": "  wp_pures",
  "insertion": {
    "path": "Liris/Tests/OneShot.lean",
    "version": 1,
    "line": 2549,
    "character": 0
  }
}
```

Human output should include a bounded numbered excerpt around the failing
submitted line.

## Evidence

Imported from the LIRIS card set. Raw proofmode traces were not copied into
this public repository.

## Current Workaround

For large speculative snippets, keep the exact snippet in report evidence or
write the successful shape to a saved reduced regression quickly. Do not rely
on memory to map `<runAt>` line numbers.
