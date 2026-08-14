# ULC-0003 Structured setup-file Dependency Build Progress

Status: open
Kind: upstream-api
Priority: high
Origin: upstream Lean backlog
Last reviewed: 2026-07-08
Issue: none linked
Lean PR: none linked
Upstream timing: as soon as possible

## Summary

Lean already exposes structured `$/lean/fileProgress` for file elaboration, but
file-worker `lake setup-file` dependency-build progress is currently exposed as
ordinary information diagnostics with a synthetic file-start range. Beam
recognizes Lake build-monitor text so MCP and wrapper clients can see cold
setup activity during long syncs and `runAt` probes.

## Impact

- Matching diagnostic text is deliberately brittle.
- Dependency-build progress appears through the same channel as user-facing
  diagnostics.
- Cold-start reporting is less structured than Lean's ordinary file-progress
  stream.

## Upstream Decision

Track as an active Lean-cycle feature alongside
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md). It
would keep dependency-build progress out of ordinary diagnostics and give
clients a typed cold-start signal. Beam can still make
[BUC-0006](../BUC-0006-cold-start-daemon-lifecycle/README.md) failures
reportable with the information it already has, but the current text matcher
should stay visibly temporary.

## Reproduction Status

No upstream Lean PR is linked yet. Beam currently has a narrow local matcher for
Lake build-monitor diagnostic text and tests around progress/readiness
separation. Lean v4.31.0 already has structured `$/lean/fileProgress` for file
elaboration, so the missing piece is specifically setup-file dependency-build
progress.

## Preliminary Analysis

This should be scoped to the `lake setup-file` stderr/progress path, not general
Lean file progress. Lean already reports document elaboration ranges through
`$/lean/fileProgress`; setup-file progress is the outlier because the file
worker currently projects Lake build-monitor lines as temporary information
diagnostics. The likely upstream fix is either to extend `$/lean/fileProgress`
with setup/build progress entries or add a sibling setup-progress notification.

## Expected Behavior

Lean should expose typed setup-file dependency-build progress through an LSP
notification or API that includes:

- document URI/version;
- phase such as `setupFile` or `dependencyBuild`;
- status such as `running`, `done`, or `failed`;
- optional target/module caption;
- bounded detail text from Lake build output.

Beam would stop matching build-monitor diagnostic strings for progress and
would keep ordinary diagnostics free of transient setup/build progress lines.

## Evidence

The current workaround is documented in
[Development](../../../DEVELOPMENT.md#lean-api-workaround-notes), and the narrow
matcher lives near `Beam/Broker/SyncSaveSupport.lean`.

Relevant Lean v4.31.0 implementation points:

- `$/lean/fileProgress` already reports structured file elaboration progress;
- `Lean.Server.FileWorker.setupFile` currently maps Lake stderr lines to
  information diagnostics at a synthetic file-start range;
- Beam recognizes only the temporary diagnostic envelope plus Lake
  build-monitor line shape.

## Current Workaround

Keep string matching narrow and isolated. Do not use setup progress as a
readiness authority.
