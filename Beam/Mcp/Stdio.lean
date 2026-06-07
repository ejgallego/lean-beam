/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Mcp.Stdio

def isBrokenPipeError (err : IO.Error) : Bool :=
  let msg := err.toString
  msg.contains "broken pipe" || msg.contains "Broken pipe" || msg.contains "EPIPE"

def stripLineEnding (line : String) : String :=
  let line :=
    if !line.isEmpty && line.back == '\n' then
      line.dropEnd 1 |>.copy
    else
      line
  if !line.isEmpty && line.back == '\r' then
    line.dropEnd 1 |>.copy
  else
    line

def writeJsonLineToStream (stream : IO.FS.Stream) (json : Json) : IO Unit := do
  stream.putStr (json.compress ++ "\n")
  stream.flush

def writeJsonLineToHandle (handle : IO.FS.Handle) (json : Json) : IO Unit := do
  handle.putStr (json.compress ++ "\n")
  handle.flush

def writeStdoutJsonLine (json : Json) : IO Unit := do
  let stdout ← IO.getStdout
  writeJsonLineToStream stdout json

end Beam.Mcp.Stdio
