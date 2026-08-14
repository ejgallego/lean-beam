# BUC-0008 Agent Feedback Card API

Status: resolved
Kind: feature
Priority: medium
Origin: LIRIS
Last reviewed: 2026-07-08
Issue: none linked

## Summary

Agents needed a lightweight MCP-native way to turn a Beam observation into a
structured upstream card or bug report while runtime identity, request
parameters, diagnostics, and evidence were still available.

## Impact

- Before Beam feedback, useful repro detail could be lost during long agent
  sessions.
- Feedback was spread across chat transcripts, board logs, and ad hoc incident
  notes.
- MCP needed a compact result shape that did not flood agent context by default.

## Beam Decision

Archived. The implemented `lean-beam feedback` and MCP `beam_feedback`
surfaces now produce structured report-card JSON, pasteable Markdown,
metadata, collection warnings, optional bundles, compact MCP defaults, and
optional full collected context.

Keep a separate future card only if Beam should directly write LIRIS-style card
directories. That would be a repository workflow tool, not the core feedback
report-card surface.

## Reproduction Status

Retest passed locally on 2026-07-07:

```text
lake build beam-feedback-test beam-mcp-projection-test beam-mcp-protocol-test
.lake/build/bin/beam-feedback-test
.lake/build/bin/beam-mcp-projection-test
.lake/build/bin/beam-mcp-protocol-test
```

These tests cover structured input validation, bundles, compact MCP feedback,
`include_collected`, metadata, and the MCP tool schema.

## Preliminary Analysis

The original proposal bundled two separate ideas: a bug-report surface and a
downstream card-directory writer. The bug-report surface is implemented. A
card-directory writer would be repository workflow automation, should default
to dry-run, and should stay outside the core Beam feedback report-card API
until a concrete maintainer workflow requires it.

## Expected Behavior

The current report-card surface should remain small:

- accept structured JSON input rather than free-form notes;
- collect version, stats, open-file, registry, and incident context when cheap;
- return compact MCP results by default;
- preserve full collected debug JSON in CLI output and bundles.

## Evidence

Current behavior is documented in [Feedback Report Cards](../../../FEEDBACK.md).

## Current Workaround

Use `lean-beam feedback` or MCP `beam_feedback`, then manually place the
pasteable Markdown or evidence bundle into the downstream project tracker.
