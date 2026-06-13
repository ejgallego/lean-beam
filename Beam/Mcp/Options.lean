/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

namespace Beam.Mcp

structure Options where
  root? : Option String := none
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  beamCli? : Option String := none
  selfCheckPath? : Option String := none

def usage : String :=
  String.intercalate "\n" [
    "usage: lean-beam-mcp [--root PATH] [--beam-cli PATH] [--lean-cmd CMD] [--lean-plugin PATH]",
    "       lean-beam-mcp [--root PATH] [--beam-cli PATH] --self-check <lean-file>",
    "",
    "Runs the experimental Lean Beam MCP server over newline-delimited JSON-RPC on stdio.",
    "When --root is omitted, call lean_init_workspace with an absolute Lean project root or let the server discover one project root via MCP roots/list.",
    "--self-check starts a child MCP server, calls lean_init_workspace, and then calls lean_sync.",
    "The installed wrapper passes --beam-cli automatically so project-specific Lean bundles resolve on demand.",
    "Only curated Lean tools are exposed; raw LSP and broker escape hatches are intentionally absent."
  ]

partial def parseOptions (opts : Options) : List String → Except String Options
  | [] => pure opts
  | "--root" :: root :: rest =>
      parseOptions { opts with root? := some root } rest
  | "--lean-cmd" :: leanCmd :: rest =>
      parseOptions { opts with leanCmd? := some leanCmd } rest
  | "--lean-plugin" :: leanPlugin :: rest =>
      parseOptions { opts with leanPlugin? := some leanPlugin } rest
  | "--beam-cli" :: beamCli :: rest =>
      parseOptions { opts with beamCli? := some beamCli } rest
  | "--self-check" :: path :: rest =>
      parseOptions { opts with selfCheckPath? := some path } rest
  | "-h" :: _ | "--help" :: _ =>
      throw usage
  | arg :: _ =>
      throw s!"unexpected lean-beam-mcp argument '{arg}'\n\n{usage}"

end Beam.Mcp
