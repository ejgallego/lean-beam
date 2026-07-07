# Feedback Report Cards

`lean-beam feedback` and MCP `beam_feedback` produce a structured Beam report card for bug reports
and project feedback. The output is JSON with a pasteable Markdown `markdown` field, structured
`metadata`, collected Beam debug context, and optional evidence bundle paths.

## CLI

```bash
lean-beam --root /path/to/project feedback --stdin
lean-beam --root /path/to/project feedback --input report.json --bundle dir
lean-beam --root /path/to/project feedback --input report.json --bundle zip --output-dir /tmp/beam-report
```

Input JSON:

```json
{
  "title": "Short report title",
  "summary": "What went wrong.",
  "kind": "bug",
  "severity": "high",
  "reproduction": "Concrete commands or steps.",
  "expected": "Expected behavior.",
  "actual": "Observed behavior.",
  "tags": ["daemon", "startup"],
  "request": {"op": "runAt"},
  "response": {"ok": false},
  "bundle": "none"
}
```

Required fields are `title`, `summary`, `reproduction`, `expected`, and `actual`. Optional
`kind` values are `bug`, `ux`, `perf`, `docs`, and `question`. Optional `severity` values are
`low`, `medium`, `high`, and `critical`. Optional `bundle` values are `none`, `dir`, and `zip`; the
default is `none`. Redaction is enabled by default and replaces the current `HOME` path with `~`;
pass `--no-redact` or `"redact": false` only when the output can safely contain local paths.

Free-form notes are not accepted directly. Wrap notes in the required JSON object fields above;
`lean-beam feedback --help` prints the accepted input shape.

Evidence entries, when present, must have a simple `name` and exactly one source: inline `content`
or a local `path`. File evidence is accepted only from the active root, Beam control directory, or
the bundle directory being written.

Redaction is intentionally narrow and best-effort. It is meant to keep ordinary home-directory
paths out of report cards, not to scrub arbitrary secrets, access tokens, private repository names,
or sensitive source snippets. Review the rendered report before sharing it publicly.

When a project root is available, the CLI includes Beam identity, live daemon stats, open files,
daemon registry status, startup log tail, and recent daemon incident records.

## MCP

Call `beam_feedback` with the same required fields. MCP returns compact report-card JSON in
`structuredContent`: `markdown`, `metadata`, `collection_warnings`, and any bundle paths. The
default Markdown includes a short Beam runtime summary instead of the full collected debug JSON.
Pass `include_collected: true` to include the full collected Beam debug context inline and render
the full debug-context section in Markdown.

MCP does not start a Lean runtime just to collect feedback. When a root is known, it includes daemon
registry and recent daemon incident context. When a runtime is active, it also includes in-process
stats and open-file data. MCP evidence bundles require an active root; use the CLI with
`--output-dir` when a bundle is needed before a root is available.

## Output

The top-level JSON object contains:

- `markdown`: pasteable report card
- `metadata`: schema, title, kind, severity, timestamp, active root, tags, bundle mode, and request id
- `collected`: Beam identity, stats, open files, and daemon context; always present in CLI output
  and in MCP output only when `include_collected: true`
- `collection_warnings`: non-fatal context collection failures
- `bundle_dir` and `zip_path`: present only when a bundle is requested and written

When redaction is disabled with `"redact": false`, MCP returns `bundle_dir` and `zip_path` as local
machine paths. With the default redaction setting, paths under `HOME` are rendered with `~`.

Evidence bundles contain `card.md`, `metadata.json`, `collected.json`, `report.json`, and an
`evidence/` directory when caller-supplied evidence is present.
