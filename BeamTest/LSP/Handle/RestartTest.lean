/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Scenario

open Lean
open BeamTest.LSP.Scenario

namespace BeamTest.LSP.Handle.RestartTest

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

private def mintHandle : IO Beam.LSP.RunAt.Handle := BeamTest.LSP.Scenario.run do
  let branch ← openDoc "tests/scenario/docs/BranchProof.lean"
  let mintReq ← sendRunAt branch { line := 0, character := 27, text := "constructor", storeHandle := true }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected restart handle"
  closeDoc branch
  pure handle

private def assertRestartInvalidated (handle : Beam.LSP.RunAt.Handle) : IO Unit := BeamTest.LSP.Scenario.run do
  let branch ← openDoc "tests/scenario/docs/BranchProof.lean"
  let req ← runWithHandle branch handle { text := "exact trivial" }
  expectErrorContains req contentModifiedJson
  closeDoc branch

def main : IO Unit := do
  let handle ← mintHandle
  assertRestartInvalidated handle

end BeamTest.LSP.Handle.RestartTest

def main := BeamTest.LSP.Handle.RestartTest.main
