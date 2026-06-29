/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import BeamTest.Broker.ProcessUtil

open Lean

namespace BeamTest.Broker.TestUtil

structure StreamRun where
  exitCode : UInt32
  stderr : String
  messages : Array Beam.Broker.StreamMessage

private def decodeStreamLines (output : String) : IO (Array Beam.Broker.StreamMessage) := do
  let lines :=
    output.split (· == '\n') |>.filterMap fun line =>
      let line := line.trimAscii.toString
      if line.isEmpty then none else some line
  if lines.isEmpty then
    throw <| IO.userError "expected request-stream output"
  lines.toArray.mapM fun line =>
    match Json.parse line with
    | .error err => throw <| IO.userError s!"invalid request-stream json line: {err}\n{line}"
    | .ok json =>
        IO.ofExcept <| fromJson? json

def runRequestStream
    (port : UInt16)
    (req : Beam.Broker.Request) : IO StreamRun := do
  let out ← IO.Process.output {
    cmd := (← clientExe).toString
    args := #["--port", toString port.toNat, "request-stream", (toJson req).compress]
  }
  let messages ← decodeStreamLines out.stdout
  pure {
    exitCode := out.exitCode
    stderr := out.stderr
    messages
  }

def requireSuccessStream (label : String) (run : StreamRun) :
    IO (Array Beam.Broker.StreamMessage) := do
  if run.exitCode != 0 then
    throw <| IO.userError
      s!"expected {label} request-stream success, got exit {run.exitCode}\nstderr:\n{run.stderr}"
  unless run.stderr.trimAscii.toString.isEmpty do
    throw <| IO.userError s!"expected {label} request-stream stderr to stay empty, got:\n{run.stderr}"
  pure run.messages

def requireFailedStream (label : String) (run : StreamRun) :
    IO (Array Beam.Broker.StreamMessage) := do
  if run.exitCode == 0 then
    throw <| IO.userError s!"expected {label} request-stream failure"
  unless run.stderr.trimAscii.toString.isEmpty do
    throw <| IO.userError s!"expected {label} request-stream stderr to stay empty, got:\n{run.stderr}"
  pure run.messages

end BeamTest.Broker.TestUtil
