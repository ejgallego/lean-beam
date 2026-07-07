# BUC-0008 Agent Feedback Card API

Status: close-candidate
Kind: feature
Priority: medium
Origin: LIRIS
Last reviewed: 2026-07-07

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

Close or archive. The implemented `lean-beam feedback` and MCP `beam_feedback`
surfaces now produce structured report-card JSON, pasteable Markdown, metadata,
collection warnings, optional bundles, compact MCP defaults, and optional full
collected context.

Keep a separate future card only if Beam should directly write LIRIS-style card
directories. That would be a repository workflow tool, not the core feedback
report-card surface.

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
