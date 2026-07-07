# Compatibility Policy

Lean Beam is beta software. Preserve compatibility only for named external or versioned targets; do
not keep payload shapes, aliases, command spellings, permissive decoders, or harness behavior for
hypothetical clients.

## Current Targets

- The core product goal is still the small Lean request shaped like `runAt(pos, "lean text")`,
  with typed request and response data.
- Supported Lean toolchains listed in `supported-lean-toolchains`. Shims must name the Lean/Lake API
  boundary they support and should be removed when the support window no longer needs them.
- Versioned runtime bundle metadata and install-layout schemas.
- The MCP protocol revision currently advertised by `lean-beam-mcp` and its conformance baseline.
- Documented real client requirements, when they name an owner and removal condition.

## Change Rule

CLI and MCP command/tool surfaces are discoverable from the installed skill file, help text, and MCP
`tools/list` schemas. During beta, discovery is the compatibility story for those surfaces. The
local broker JSON stream is an implementation boundary, and maintainer harness scripts are local
contributor tooling. LSP compatibility is not a release target until after beta.

If a compatibility branch, deprecated field, alias, or permissive decoder cannot name one of the
current targets above, remove it and update docs/tests to the current typed contract.

## Beta Deprecations

Beta deprecations should be short and explicit: document the replacement and removal trigger in the
same change. Otherwise, treat the surface as current behavior, not compatibility policy.
