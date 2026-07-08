# ULC-0006 Compatibility Shim Retirement

Status: open
Kind: cleanup
Priority: low
Origin: upstream Lean backlog
Last reviewed: 2026-07-08
Issue: none linked
Lean PR: none linked
Upstream timing: next supported-toolchain bump

## Summary

Beam carries compatibility shims for supported Lean versions across API
boundaries such as file source identity, Lake pure traces, C emission,
diagnostic collection, TCP transport, and module output descriptors.

## Impact

- Compatibility branches add maintenance cost.
- Some shims can be deleted only when the supported toolchain window no longer
  crosses the relevant Lean/Lake API boundary.
- Keeping obsolete shims conflicts with Beam's pre-stable compatibility policy.

## Upstream Decision

Track as compatibility cleanup tied to Beam's supported Lean toolchain window.
This is not a Lean API proposal and not a Beam release-theme card; it becomes
actionable when Beam deliberately drops a toolchain boundary named in
`docs/DEVELOPMENT.md`.

## Reproduction Status

No retest needed until Beam changes its supported Lean toolchain window. The
current shim list is code-local maintainer guidance, not a live bug.

## Preliminary Analysis

This card is useful as a retirement checklist, but it should stay out of
feature planning. Revisit when a release deliberately drops one of the
toolchain boundaries named in `docs/DEVELOPMENT.md`.

## Expected Behavior

When Beam drops support for an older toolchain boundary, remove the obsolete
shim and update docs/tests to the current typed contract.

## Evidence

The current shim list lives in
[Development](../../../DEVELOPMENT.md#lean-428-compatibility-shims) and
[Development](../../../DEVELOPMENT.md#lean-430-through-432-compatibility-shims).

## Current Workaround

Keep shims named, documented, and tied to explicit supported Lean toolchains.
Do not preserve compatibility branches that cannot name a supported target.
