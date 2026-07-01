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

def run : ScenarioM Unit := do
  checkGoalsPrev
  checkGoalsAfter
  checkGoalsPrevInvalidPosition
  checkGoalsAfterInvalidPosition
  checkGoalsPrevStaleVersion
  checkGoalsAfterStaleVersion
  checkGoalsPrevWithStandardLspInterference
  checkGoalsAfterWithStandardLspInterference

end BeamTest.LSP.Requests.Goals.BasicTest
