/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Lean.Workspace
import Beam.Mcp.Protocol

open Lean

namespace Beam.Mcp.Roots

def unsupportedMessage : String :=
  "MCP client did not advertise roots; call lean_init_workspace with {\"root\":\"/path/to/lean/project\"}, start lean-beam-mcp with --root PATH, or enable the client's roots capability"

def selectClientRoot (roots : Array ClientRoot) : Except String System.FilePath := do
  if roots.size == 0 then
    throw "MCP client returned no roots; start lean-beam-mcp with --root PATH or configure exactly one project root"
  else if roots.size > 1 then
    throw "MCP client returned multiple roots; start lean-beam-mcp with --root PATH until multi-root selection is supported"
  else
    let root := roots[0]!
    match System.Uri.fileUriToPath? root.uri with
    | some path => pure path
    | none => throw s!"MCP client root URI must be a file:// URI, got {root.uri}"

def selectClientRootResponse (response : IncomingResponse) : IO (Except String System.FilePath) := do
  match response.outcome with
  | .error err =>
      pure <| .error s!"roots/list failed: {(toJson err).compress}"
  | .result rawResult =>
      let result ←
        match fromJson? (α := ListRootsResult) rawResult with
        | .ok result => pure result
        | .error err => return .error err
      match selectClientRoot result.roots with
      | .error err => pure <| .error err
      | .ok root =>
          match ← Beam.Lean.Workspace.resolveRoot root.toString with
          | .ok root => pure <| .ok root
          | .error err => pure <| .error err.message

end Beam.Mcp.Roots
