/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Scenario

open Lean
open BeamTest.LSP.Scenario

namespace BeamTest.LSP.Handle.Api

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

private def mintProofHandle (label : String) (doc : DocHandle) :
    ScenarioM Beam.LSP.RunAt.Handle := do
  let mintReq ← sendRunAt doc {
    line := 1
    character := 2
    text := "change True"
    storeHandle := true
  }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs mintReq
  unless mint.success do
    throw <| IO.userError s!"{label}: expected handle-minting runAt to succeed"
  let some handle := mint.handle?
    | throw <| IO.userError s!"{label}: expected stored handle"
  pure handle

def checkRunWithContinuation : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  syncDoc doc
  let handle ← mintProofHandle "runWith continuation" doc

  let continueReq ← runWithHandle doc handle { text := "exact trivial" }
  let continued : Beam.LSP.RunAt.Result ← awaitResponseAs continueReq
  unless continued.success do
    throw <| IO.userError "runWith continuation: expected successor to succeed"
  let some proofState := continued.proofState?
    | throw <| IO.userError "runWith continuation: expected proofState"
  unless proofState.goals.isEmpty do
    throw <| IO.userError
      s!"runWith continuation: expected solved proof state, got {(toJson proofState).compress}"

  closeDoc doc

def checkReleaseHandleRejectsReleasedHandle : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  syncDoc doc
  let handle ← mintProofHandle "releaseHandle" doc

  releaseHandle doc handle

  let rejectedReq ← runWithHandle doc handle { text := "exact trivial" }
  expectErrorContains rejectedReq invalidParamsJson

  closeDoc doc

def checkRunWithFailureDoesNotStoreHandle : ScenarioM Unit := do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"

  -- The scenario DSL cannot currently assert that a failed request did *not* return a handle.
  let mintReq ← sendRunAt cmd { line := 0, character := 2, text := "def tempNoHandle : Nat := 9", storeHandle := true }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected command handle"

  let failureReq ← runWithHandle cmd handle {
    text := "#check MissingNameAgain"
    storeHandle := true
    linear := true
  }
  let failure : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) failureReq
  if failure.success then
    throw <| IO.userError "expected semantic failure for failed successor handle test"
  if failure.handle?.isSome then
    throw <| IO.userError "did not expect successor handle on semantic failure"

  closeDoc cmd

def run : ScenarioM Unit := do
  checkRunWithContinuation
  checkReleaseHandleRejectsReleasedHandle
  checkRunWithFailureDoesNotStoreHandle

end BeamTest.LSP.Handle.Api
