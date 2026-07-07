# BUC-0004 runAt Diagnostic Origin Mapping

Status: candidate-0.2.0
Kind: diagnostics
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07
Issue: none linked

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

## Reproduction Status

Reproduced locally on 2026-07-07 with a small fixture:

```text
scripts/lean-beam --root tests/save_olean_project update GoalSmoke.lean
scripts/lean-beam --root tests/save_olean_project run-at GoalSmoke.lean 1 1 2 $'exact true\n  broken syntax'
```

The result was a normal semantic failure with only a rendered message location:

```json
{
  "severity": "error",
  "text": "<runAt>:2:9: expected end of input"
}
```

The result did not include a structured range in the submitted text, a submitted
text hash, or insertion-site metadata.

## Preliminary Analysis

The current `RunAt.Message` payload contains only `severity` and `text`.
`messagesToProtocol` converts `Lean.Message` values to rendered strings and
drops position data. Both command and tactic parser paths use a synthetic input
context named `<runAt>`, so parser errors can only point at that rendered
synthetic file name.

Smallest fix direction: extend the internal runAt message projection with an
optional origin object for messages generated from submitted `runAt` text. For
parser errors, map the reported synthetic position through the submitted text's
file map. For elaboration messages whose positions also belong to the
submitted text, preserve the same origin. Keep the public request unchanged;
only enrich the result and CLI/MCP projections.

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

Related Beam issues may cover adjacent `runAt` ergonomics, for example
[lean-beam#100](https://github.com/ejgallego/lean-beam/issues/100) for
multi-command snippets. This card is narrower: it tracks origin mapping for
diagnostics that already come from synthetic `runAt` buffers.

## Current Workaround

For large speculative snippets, keep the exact snippet in report evidence or
write the successful shape to a saved reduced regression quickly. Do not rely
on memory to map `<runAt>` line numbers.
