/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario
import RunAt.Internal.SaveSupport

open Lean
open RunAtTest.Scenario

namespace RunAtTest.Scenario.ApiTest

private def successJson : Json :=
  Json.mkObj [("success", toJson true)]

private def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

private def checkConcurrentRequests : ScenarioM Unit := do
  let proofA ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let proofB ← openDoc "tests/scenario/docs/SimpleProofB.lean"
  let cmdA ← openDoc "tests/scenario/docs/CommandA.lean"

  let staleReqs ← (List.range 5).mapM fun _ =>
    sendRunAt proofA { line := 1, character := 2, text := "exact trivial" }
  let proofReqs ← (List.range 3).mapM fun _ =>
    sendRunAt proofB { line := 1, character := 2, text := "exact trivial" }
  let commandReqs ← (List.range 2).mapM fun _ =>
    sendRunAt cmdA { line := 0, character := 2, text := "#check Nat" }

  changeDoc proofA { line := 0, character := 0, delete := "", insert := " " }
  syncDoc proofA

  for req in staleReqs do
    expectErrorContains req contentModifiedJson

  for req in proofReqs do
    expectResponseContains req successJson

  for req in commandReqs do
    expectResponseContains req successJson

  closeDoc proofA
  closeDoc proofB
  closeDoc cmdA

private def checkDependentProbeAssembly : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/DependentProbeAssembly.lean"

  -- Each probe is valid against the original snapshot, but committing only the value
  -- edit makes the dependent proof stale.
  let valueReq ← sendRunAt doc { line := 2, character := 4, text := "exact 1" }
  let proofReq ← sendRunAt doc { line := 4, character := 4, text := "rfl" }

  expectResponseContains valueReq successJson
  expectResponseContains proofReq successJson

  changeDoc doc { line := 2, character := 4, delete := "exact 0", insert := "exact 1" }
  syncDoc doc

  let readinessReq ← sendSaveReadiness doc
  let readiness : RunAt.Internal.SaveReadinessResult ← awaitResponseAs readinessReq
  if readiness.saveReady then
    throw <| IO.userError
      s!"dependent probe assembly: expected committed document to have errors, got {(toJson readiness).compress}"
  if readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty then
    throw <| IO.userError
      s!"dependent probe assembly: expected save-blocking evidence, got {(toJson readiness).compress}"

  closeDoc doc

private def boolVersionText : String :=
  "example : Bool := by\n  exact true"

private def commandOnlyText : String :=
  "#check Nat"

private def replaceWholeInterleavingDoc (doc : DocHandle) (text : String) : ScenarioM Unit :=
  changeDoc doc {
    line := 0
    character := 0
    endLine? := some 1
    endCharacter? := some 9
    insert := text
  }

private def requireSingleGoalTarget (label : String) (result : RunAt.Result) : ScenarioM String := do
  if !result.success then
    throw <| IO.userError s!"{label}: expected successful runAt, got {(toJson result).compress}"
  let some proofState := result.proofState?
    | throw <| IO.userError s!"{label}: expected proofState, got {(toJson result).compress}"
  match proofState.goals.toList with
  | [goal] => pure goal.target
  | _ => throw <| IO.userError s!"{label}: expected one goal, got {(toJson proofState).compress}"

private def expectRunAtTarget
    (label : String)
    (doc : DocHandle)
    (line character : Nat)
    (expected : String) : ScenarioM Unit := do
  let req ← sendRunAt doc { line, character, text := "skip" }
  let result : RunAt.Result ← awaitResponseAs req
  let target ← requireSingleGoalTarget label result
  if target != expected then
    throw <| IO.userError s!"{label}: expected target {expected}, got {target}"

private def checkSyncRunAtInterleavings : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SyncRunAtInterleaving.lean"
  syncDoc doc

  expectRunAtTarget "initial runAt" doc 1 2 "Nat"

  replaceWholeInterleavingDoc doc boolVersionText
  syncDoc doc

  let staleReq ← sendRunAt doc { version? := some 1, line := 1, character := 2, text := "skip" }
  expectErrorContains staleReq contentModifiedJson

  -- The same coordinate is valid only when paired with the freshly synced version.
  expectRunAtTarget "runAt after sync at same coordinate" doc 1 2 "Bool"

  closeDoc doc

  let doc ← openDoc "tests/scenario/docs/SyncRunAtInterleaving.lean"
  replaceWholeInterleavingDoc doc boolVersionText
  let beforeBarrier ← sendRunAt doc { line := 1, character := 2, text := "skip" }
  syncDoc doc
  let beforeBarrierResult : RunAt.Result ← awaitResponseAs beforeBarrier
  let beforeBarrierTarget ← requireSingleGoalTarget "runAt after change before sync" beforeBarrierResult
  if beforeBarrierTarget != "Bool" then
    throw <| IO.userError
      s!"runAt after change before sync: expected target Bool, got {beforeBarrierTarget}"
  closeDoc doc

  let doc ← openDoc "tests/scenario/docs/SyncRunAtInterleaving.lean"
  syncDoc doc
  replaceWholeInterleavingDoc doc commandOnlyText
  syncDoc doc
  let staleReq ← sendRunAt doc { line := 1, character := 2, text := "skip" }
  expectErrorContains staleReq invalidParamsJson
  closeDoc doc

def main : IO Unit := RunAtTest.Scenario.run do
  checkConcurrentRequests
  checkDependentProbeAssembly
  checkSyncRunAtInterleavings

end RunAtTest.Scenario.ApiTest

def main := RunAtTest.Scenario.ApiTest.main
