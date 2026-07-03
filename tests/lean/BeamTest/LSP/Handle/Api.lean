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

private def requireStoredHandle (label : String) (result : Beam.LSP.RunAt.Result) :
    ScenarioM Beam.LSP.RunAt.Handle := do
  unless result.success do
    throw <| IO.userError s!"{label}: expected handle-minting request to succeed"
  let some handle := result.handle?
    | throw <| IO.userError s!"{label}: expected stored handle"
  pure handle

private def mintProofHandle (label : String) (doc : DocHandle) :
    ScenarioM Beam.LSP.RunAt.Handle := do
  let mintReq ← sendRunAt doc {
    line := 1
    character := 2
    text := "change True"
    storeHandle := true
  }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs mintReq
  requireStoredHandle label mint

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

def checkRunWithLinearHandle : ScenarioM Unit := do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"

  let mintReq ← sendRunAt cmd {
    line := 0
    character := 2
    text := "def tempLinear : Nat := 5"
    storeHandle := true
  }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs mintReq
  let handle ← requireStoredHandle "runWith linear initial handle" mint

  let nextReq ← runWithHandle cmd handle {
    text := "def tempLinearNext : Nat := tempLinear"
    storeHandle := true
    linear := true
  }
  let next : Beam.LSP.RunAt.Result ← awaitResponseAs nextReq
  let nextHandle ← requireStoredHandle "runWith linear successor handle" next

  let oldReq ← runWithHandle cmd handle { text := "#check tempLinear" }
  expectErrorContains oldReq invalidParamsJson

  let newReq ← runWithHandle cmd nextHandle { text := "#check tempLinearNext" }
  let newResult : Beam.LSP.RunAt.Result ← awaitResponseAs newReq
  unless newResult.success do
    throw <| IO.userError
      s!"runWith linear successor: expected new handle to succeed, got {(toJson newResult).compress}"

  closeDoc cmd

def checkRunWithFailureDoesNotStoreHandle : ScenarioM Unit := do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"

  -- The scenario DSL cannot currently assert that a failed request did *not* return a handle.
  let mintReq ← sendRunAt cmd { line := 0, character := 2, text := "def tempNoHandle : Nat := 9", storeHandle := true }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) mintReq
  let handle ← requireStoredHandle "failed successor no-handle initial handle" mint

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

def checkRunAtHandleTermAscriptionFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TermAscriptionProof.lean"

  let req ← sendRunAt doc {
    line := 2
    character := 2
    text := "have htest := (Nat.succ : Nat)"
    storeHandle := true
  }
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) req
  if result.success then
    throw <| IO.userError s!"expected runAt-handle semantic failure, got {(toJson result).compress}"
  if result.handle?.isSome then
    throw <| IO.userError "did not expect handle on failed term-ascription probe"
  unless result.messages.any (fun msg =>
      msg.severity == MessageSeverity.error && msg.text.contains "Type mismatch") do
    throw <| IO.userError
      s!"expected type mismatch diagnostic for term-ascription probe, got {(toJson result).compress}"

  closeDoc doc

def run : ScenarioM Unit := do
  checkRunWithContinuation
  checkReleaseHandleRejectsReleasedHandle
  checkRunWithLinearHandle
  checkRunWithFailureDoesNotStoreHandle
  checkRunAtHandleTermAscriptionFailure

end BeamTest.LSP.Handle.Api
