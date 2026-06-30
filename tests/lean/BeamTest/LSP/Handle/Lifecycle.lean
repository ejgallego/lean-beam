/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Scenario

open Lean
open BeamTest.LSP.Scenario

namespace BeamTest.LSP.Handle.Lifecycle

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

private def expectHandleResultErrorTwice
    (doc : DocHandle)
    (handle : Beam.LSP.RunAt.Handle)
    (text : String) : ScenarioM Unit := do
  let reqA ← runWithHandle doc handle { text }
  expectErrorContains reqA contentModifiedJson
  let reqB ← runWithHandle doc handle { text }
  expectErrorContains reqB contentModifiedJson

def checkEditPruning : ScenarioM Unit := do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"
  let mintReq ← sendRunAt cmd {
    line := 0
    character := 2
    text := "def tempLifecycle : Nat := 1"
    storeHandle := true
  }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected lifecycle edit handle"

  changeDoc cmd { line := 0, character := 23, insert := " " }
  syncDoc cmd

  let freshReq ← sendRunAt cmd {
    line := 0
    character := 2
    text := "#check Nat"
    storeHandle := true
  }
  let _fresh : Beam.LSP.RunAt.Result ← awaitResponseAs freshReq

  expectHandleResultErrorTwice cmd handle "#check tempLifecycle"
  closeDoc cmd

def checkClosePruning : ScenarioM Unit := do
  let branch ← openDoc "tests/scenario/docs/BranchProof.lean"
  let mintReq ← sendRunAt branch {
    line := 0
    character := 27
    text := "constructor"
    storeHandle := true
  }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected lifecycle close handle"
  closeDoc branch

  let branch2 ← openDoc "tests/scenario/docs/BranchProof.lean"
  let freshReq ← sendRunAt branch2 {
    line := 0
    character := 27
    text := "constructor"
    storeHandle := true
  }
  let _fresh : Beam.LSP.RunAt.Result ← awaitResponseAs freshReq

  expectHandleResultErrorTwice branch2 handle "exact trivial"
  closeDoc branch2

def run : ScenarioM Unit := do
  checkEditPruning
  checkClosePruning

end BeamTest.LSP.Handle.Lifecycle
