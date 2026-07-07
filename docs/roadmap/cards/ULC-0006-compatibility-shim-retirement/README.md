# ULC-0006 Compatibility Shim Retirement

Status: deferred
Kind: cleanup
Priority: low
Origin: upstream Lean backlog
Last reviewed: 2026-07-07
Issue: none linked
Lean PR: none linked

## Summary

Beam carries compatibility shims for supported Lean versions across API
boundaries such as file source identity, Lake pure traces, C emission,
diagnostic collection, TCP transport, and module output descriptors.

## Impact

- Compatibility branches add maintenance cost.
- Some shims can be deleted only when the supported toolchain window no longer
  crosses the relevant Lean/Lake API boundary.
- Keeping obsolete shims conflicts with Beam's alpha compatibility policy.

## Beam Decision

Defer from 0.2.0 unless the supported toolchain list changes. This is a cleanup
card, not a user-facing release theme.

## Reproduction Status

No retest needed until Beam changes its supported Lean toolchain window. The
current shim list is code-local maintainer guidance, not a live bug.

## Preliminary Analysis

This card is useful as a retirement checklist, but it should stay out of the
0.2.0 reliability theme. Revisit when a release deliberately drops one of the
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
