/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Protocol

open Lean

namespace Beam.Mcp.Roots

def unsupportedMessage : String :=
  "MCP client did not advertise roots; start lean-beam-mcp with --root PATH or enable the client's roots capability"

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

private def stripLineEnding (line : String) : String :=
  let line :=
    if !line.isEmpty && line.back == '\n' then
      line.dropEnd 1 |>.copy
    else
      line
  if !line.isEmpty && line.back == '\r' then
    line.dropEnd 1 |>.copy
  else
    line

partial def requestClientRoot
    (stdin : IO.FS.Stream)
    (writeJsonLine : Json → IO Unit) : IO (Except String System.FilePath) := do
  try
    writeJsonLine rootsListRequest
    let rec waitForResponse : IO (Except String System.FilePath) := do
      let line := stripLineEnding (← stdin.getLine)
      if line.isEmpty then
        pure <| .error "MCP client closed stdin before answering roots/list"
      else
        match Json.parse line with
        | .error err =>
            pure <| .error s!"MCP client roots/list response is not valid JSON: {err}"
        | .ok json =>
            match json.getObjVal? "method" with
            | .ok _ =>
                match Incoming.fromJson? json with
                | .ok (.request req) =>
                    writeJsonLine <|
                      errorResponse req.id <|
                        RpcError.invalidRequest "cannot process client request while waiting for roots/list response"
                    waitForResponse
                | .ok (.notification notification) =>
                    if notification.method == "exit" then
                      pure <| .error "MCP client exited before answering roots/list"
                    else
                      waitForResponse
                | .error err =>
                    pure <| .error err
            | .error _ =>
                match parseRootsListResponse json with
                | .error err => pure <| .error err
                | .ok result =>
                    match selectClientRoot result.roots with
                    | .error err => pure <| .error err
                    | .ok root =>
                        let root ← IO.FS.realPath root
                        pure <| .ok root
    waitForResponse
  catch e =>
    pure <| .error e.toString

end Beam.Mcp.Roots
