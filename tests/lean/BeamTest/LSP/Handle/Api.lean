/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Scenario

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference

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

private def mintProofHandleAt (label : String) (doc : DocHandle) (line character : Nat) :
    ScenarioM Beam.LSP.RunAt.Handle := do
  let mintReq ← sendRunAt doc {
    line
    character
    text := "change True"
    storeHandle := true
  }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs mintReq
  requireStoredHandle label mint

private def mintProofHandle (label : String) (doc : DocHandle) :
    ScenarioM Beam.LSP.RunAt.Handle :=
  mintProofHandleAt label doc 1 2

private def requireSuccessResult (label : String) (result : Beam.LSP.RunAt.Result) :
    ScenarioM Unit := do
  unless result.success do
    throw <| IO.userError s!"{label}: expected request to succeed, got {(toJson result).compress}"

private def requireSolvedProofState (label : String) (result : Beam.LSP.RunAt.Result) :
    ScenarioM Unit := do
  requireSuccessResult label result
  let some proofState := result.proofState?
    | throw <| IO.userError s!"{label}: expected proofState"
  unless proofState.goals.isEmpty do
    throw <| IO.userError
      s!"{label}: expected solved proof state, got {(toJson proofState).compress}"

def checkRunWithContinuation : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  syncDoc doc
  let handle ← mintProofHandle "runWith continuation" doc

  let continueReq ← runWithHandle doc handle { text := "exact trivial" }
  let continued : Beam.LSP.RunAt.Result ← awaitResponseAs continueReq
  requireSolvedProofState "runWith continuation" continued

  closeDoc doc

def checkRunWithWithStandardLspInterference : ScenarioM Unit := do
  let runWithDoc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"
  syncDoc runWithDoc
  let handle ← mintProofHandle "runWith with LSP interference" runWithDoc

  let continueReq ← runWithHandle runWithDoc handle { text := "exact trivial" }
  syncWhitespacePrefixEdit editDoc

  let continued : Beam.LSP.RunAt.Result ← awaitResponseAs continueReq
  requireSolvedProofState "runWith with LSP interference" continued

  closeDoc runWithDoc
  closeDoc editDoc

def checkRunWithMixedConcurrency : ScenarioM Unit := do
  let proofDoc ← openDoc "tests/scenario/docs/RunWithMixedConcurrencyProof.lean"
  let cmdDoc ← openDoc "tests/scenario/docs/CommandA.lean"
  let runAtDoc ← openDoc "tests/scenario/docs/CommandB.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"
  syncDoc proofDoc
  syncDoc cmdDoc
  let proofHandle ← mintProofHandleAt "runWith mixed concurrency proof handle" proofDoc 9 2

  let cmdMintReq ← sendRunAt cmdDoc {
    line := 0
    character := 2
    text := "def tempMixedConcurrency : Nat := 11"
    storeHandle := true
  }
  let cmdMint : Beam.LSP.RunAt.Result ← awaitResponseAs cmdMintReq
  let cmdHandle ← requireStoredHandle "runWith mixed concurrency command handle" cmdMint

  let proofReqs ← (List.range 3).mapM fun _ =>
    runWithHandle proofDoc proofHandle { text := "mixed_sleep_exact" }
  let cmdReqs ← (List.range 8).mapM fun _ =>
    runWithHandle cmdDoc cmdHandle { text := "#check tempMixedConcurrency" }
  let runAtReqs ← (List.range 6).mapM fun _ =>
    sendRunAt runAtDoc { line := 0, character := 2, text := "#check Nat" }

  syncWhitespacePrefixEdit editDoc

  for req in proofReqs do
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
    requireSolvedProofState "runWith mixed concurrency proof successor" result
  for req in cmdReqs do
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
    requireSuccessResult "runWith mixed concurrency command successor" result
  for req in runAtReqs do
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
    requireSuccessResult "runWith mixed concurrency runAt survivor" result

  closeDoc proofDoc
  closeDoc cmdDoc
  closeDoc runAtDoc
  closeDoc editDoc

def checkReleaseHandleRejectsSecondRelease : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  syncDoc doc
  let handle ← mintProofHandle "releaseHandle second release" doc

  releaseHandle doc handle

  let rejectedReq ← sendReleaseHandle doc handle
  expectErrorContains rejectedReq invalidParamsJson

  closeDoc doc

def checkRunWithRejectsReleasedHandle : ScenarioM Unit := do
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

def checkRunWithFailedLinearInvalidatesHandle : ScenarioM Unit := do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"

  let mintReq ← sendRunAt cmd {
    line := 0
    character := 2
    text := "def tempInvalidated : Nat := 9"
    storeHandle := true
  }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs mintReq
  let handle ← requireStoredHandle "runWith failed-linear invalidation initial handle" mint

  let failureReq ← runWithHandle cmd handle {
    text := "#check MissingNameInvalidation"
    linear := true
  }
  let failure : Beam.LSP.RunAt.Result ← awaitResponseAs failureReq
  if failure.success then
    throw <| IO.userError "expected semantic failure for failed-linear invalidation test"
  if failure.handle?.isSome then
    throw <| IO.userError "did not expect successor handle after failed-linear invalidation"

  let oldReq ← runWithHandle cmd handle { text := "#check tempInvalidated" }
  expectErrorContains oldReq invalidParamsJson

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
  checkRunWithWithStandardLspInterference
  checkRunWithMixedConcurrency
  checkReleaseHandleRejectsSecondRelease
  checkRunWithRejectsReleasedHandle
  checkRunWithLinearHandle
  checkRunWithFailedLinearInvalidatesHandle
  checkRunWithFailureDoesNotStoreHandle
  checkRunAtHandleTermAscriptionFailure

end BeamTest.LSP.Handle.Api
