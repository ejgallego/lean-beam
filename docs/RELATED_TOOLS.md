# Related Tools

This page explains where Lean Beam fits among nearby Lean tooling. It is descriptive, not a ranking
or replacement claim. The projects below expose different layers of Lean for different workflows,
and they may be useful together.

The descriptions here are based on each project's public documentation and published material. For
complete and current details, read the linked project documentation directly.

## Short Answer

Lean Beam is centered on a small Lean-side extension plus a thin local broker. Its main operation is
an isolated, version-bound saved-file probe: `runAt(pos, "lean text")`. The broker exposes that same
operation model through the `lean-beam` CLI and `lean-beam-mcp`.

[`lean-lsp-mcp`](https://github.com/oOo0oOo/lean-lsp-mcp) is an MCP server for Lean projects. Its
README describes agent interaction with Lean through LSP, including diagnostics, goal states, term
information, hover documentation, build-related tools, local source search, and external search
services.

[`Pantograph`](https://github.com/stanford-centaur/PyPantograph) is a machine-to-machine interface
for Lean 4. The Pantograph paper presents it as an interface for advanced theorem proving,
high-level reasoning, and data extraction, with support for proof search workflows such as Monte
Carlo Tree Search.

## Beam And lean-lsp-mcp

Both Beam and `lean-lsp-mcp` support agent workflows around Lean projects, and both can expose an
MCP server. The main difference is the integration layer each project emphasizes.

Beam starts from a Lean plugin and a small typed execution contract. The broker owns Lean LSP
sessions, routes requests, tracks document versions, and exposes CLI and MCP projections over the
same operation layer. This is why Beam emphasizes isolated saved-file probes, explicit `sync`, stale
version handling, saved snapshot checkpoints, and a deliberately small public request shape.

`lean-lsp-mcp` exposes an MCP-facing Lean toolbox. Its documented surface includes Lean LSP
inspection tools, build-oriented tools, local project search, and external search services such as
Loogle and LeanSearch.

Use Beam when the important loop is: try this Lean command or tactic here, in this saved module,
without changing the file, and keep the result tied to the document version. Use `lean-lsp-mcp` when
the important loop is: expose an MCP client to a Lean LSP, project-search, build, and theorem-search
toolbox.

## Beam And Pantograph

Beam and Pantograph are closer in spirit around machine-facing Lean interaction, but they are aimed
at different integration layers.

Beam is an agent- and tool-facing local layer around Lean LSP plus Beam-specific extensions. Its
base workflow is intentionally narrow: update or sync a saved file, run an isolated probe at a
position, inspect messages and optional proof state, then make any accepted edit in the real source.
Beam is useful for proof repair, proof translation, autoformalization experiments, and AI-assisted
editing where the target remains an ordinary Lean project on disk.

Pantograph is presented as a machine-to-machine interface for advanced theorem-proving systems. Its
paper emphasizes proof search, high-level reasoning, data extraction, and robust handling of Lean 4
inference steps. Its public API is therefore a useful reference point for systems that need a
programmatic theorem-proving interface rather than a local CLI/MCP assistant surface.

Use Beam when the client works against saved source files and needs isolated speculative checks in
the ordinary project context. Use Pantograph when the client is a theorem-proving system or research
harness that needs a programmatic proof-search, high-level reasoning, or Lean data-extraction
interface.

## What Beam Is Not Trying To Replace

Beam does not replace Lake, an editor, `lean-lsp-mcp`, Pantograph, theorem search, or prover
research frameworks. It occupies a specific layer: isolated speculative execution and related
saved-file operations, exposed consistently through a CLI, MCP server, and agent skill text.
