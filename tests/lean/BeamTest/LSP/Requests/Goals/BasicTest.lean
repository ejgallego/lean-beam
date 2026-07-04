/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support
import BeamTest.LSP.Requests.Interference

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Support
open BeamTest.LSP.Requests.Interference

namespace BeamTest.LSP.Requests.Goals.BasicTest

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

private def goalFixture : String :=
  "tests/save_olean_project/GoalSmoke.lean"

private def requireGoalsPrevState (label : String) (goals : Beam.LSP.Lib.ProofState) :
    ScenarioM Unit := do
  if goals.goals.size != 1 then
    throw <| IO.userError s!"{label}: expected one goal, got {goals.goals.size}"
  requireSingleGoalTarget label "True" goals

private def requireGoalsAfterSolved (label : String) (goals : Beam.LSP.Lib.ProofState) :
    ScenarioM Unit := do
  if goals.goals.size != 0 then
    throw <| IO.userError s!"{label}: expected solved proof state, got {goals.goals.size} goals"

def checkGoalsPrev : ScenarioM Unit := do
  let doc ← openDoc goalFixture

  let goalsPrevReq ← sendGoals doc { line := 1, character := 2, useAfter := false }
  let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsPrevReq
  requireGoalsPrevState "goals prev" goalsPrev

  closeDoc doc

def checkGoalsAfter : ScenarioM Unit := do
  let doc ← openDoc goalFixture

  let goalsAfterReq ← sendGoals doc { line := 1, character := 2, useAfter := true }
  let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsAfterReq
  requireGoalsAfterSolved "goals after" goalsAfter

  closeDoc doc

def checkGoalsPrevInvalidPosition : ScenarioM Unit := do
  let doc ← openDoc goalFixture

  let goalsPrevReq ← sendGoals doc { line := 99, character := 0, useAfter := false }

  expectErrorContains goalsPrevReq invalidParamsJson

  closeDoc doc

def checkGoalsAfterInvalidPosition : ScenarioM Unit := do
  let doc ← openDoc goalFixture

  let goalsAfterReq ← sendGoals doc { line := 99, character := 0, useAfter := true }

  expectErrorContains goalsAfterReq invalidParamsJson

  closeDoc doc

def checkGoalsPrevStaleVersion : ScenarioM Unit := do
  let doc ← openDoc goalFixture

  let goalsPrevReq ← sendGoals doc { version? := some 0, line := 1, character := 2, useAfter := false }

  expectContentModified goalsPrevReq

  closeDoc doc

def checkGoalsAfterStaleVersion : ScenarioM Unit := do
  let doc ← openDoc goalFixture

  let goalsAfterReq ← sendGoals doc { version? := some 0, line := 1, character := 2, useAfter := true }

  expectContentModified goalsAfterReq

  closeDoc doc

def checkGoalsPrevWithStandardLspInterference : ScenarioM Unit := do
  let goalsDoc ← openDoc goalFixture
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let goalsPrevReq ← sendGoals goalsDoc { line := 1, character := 2, useAfter := false }

  syncWhitespacePrefixEdit editDoc

  let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsPrevReq
  requireGoalsPrevState "goals prev with LSP interference" goalsPrev

  closeDoc goalsDoc
  closeDoc editDoc

def checkGoalsAfterWithStandardLspInterference : ScenarioM Unit := do
  let goalsDoc ← openDoc goalFixture
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let goalsAfterReq ← sendGoals goalsDoc { line := 1, character := 2, useAfter := true }

  syncWhitespacePrefixEdit editDoc

  let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsAfterReq
  requireGoalsAfterSolved "goals after with LSP interference" goalsAfter

  closeDoc goalsDoc
  closeDoc editDoc

def checkGoalsWithMixedConcurrency : ScenarioM Unit := do
  let goalsDoc ← openDoc goalFixture
  let slowDoc ← openDoc "tests/scenario/docs/RunWithMixedConcurrencyProof.lean"
  let cmdDoc ← openDoc "tests/scenario/docs/CommandB.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let slowReqs ← (List.range 3).mapM fun _ =>
    sendRunAt slowDoc { line := 9, character := 2, text := "mixed_sleep_exact" }
  let goalsPrevReqs ← (List.range 6).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := false }
  let goalsAfterReqs ← (List.range 6).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := true }
  let cmdReqs ← (List.range 6).mapM fun _ =>
    sendRunAt cmdDoc { line := 0, character := 2, text := "#check Nat" }

  syncWhitespacePrefixEdit editDoc

  for req in goalsPrevReqs do
    let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    requireGoalsPrevState "goals prev mixed concurrency" goalsPrev
  for req in goalsAfterReqs do
    let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    requireGoalsAfterSolved "goals after mixed concurrency" goalsAfter
  for req in slowReqs do
    discard <| requireRunAtResponseSuccess "goals mixed concurrency slow runAt" req
  for req in cmdReqs do
    discard <| requireRunAtResponseSuccess "goals mixed concurrency command runAt" req

  closeDoc goalsDoc
  closeDoc slowDoc
  closeDoc cmdDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkGoalsPrev
  checkGoalsAfter
  checkGoalsPrevInvalidPosition
  checkGoalsAfterInvalidPosition
  checkGoalsPrevStaleVersion
  checkGoalsAfterStaleVersion
  checkGoalsPrevWithStandardLspInterference
  checkGoalsAfterWithStandardLspInterference
  checkGoalsWithMixedConcurrency

end BeamTest.LSP.Requests.Goals.BasicTest
