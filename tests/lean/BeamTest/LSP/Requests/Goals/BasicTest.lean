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

def checkGoalsRequests : ScenarioM Unit := do
  let doc ← openDoc "tests/save_olean_project/GoalSmoke.lean"

  let goalsPrevReq ← sendGoals doc { line := 1, character := 2, useAfter := false }
  let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsPrevReq
  if goalsPrev.goals.size != 1 then
    throw <| IO.userError s!"goals prev: expected one goal, got {goalsPrev.goals.size}"
  requireSingleGoalTarget "goals prev" "True" goalsPrev

  let goalsAfterReq ← sendGoals doc { line := 1, character := 2, useAfter := true }
  let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsAfterReq
  if goalsAfter.goals.size != 0 then
    throw <| IO.userError s!"goals after: expected solved proof state, got {goalsAfter.goals.size} goals"

  closeDoc doc

def checkGoalsRequestsWithStandardLspInterference : ScenarioM Unit := do
  let goalsDoc ← openDoc "tests/save_olean_project/GoalSmoke.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let goalsPrevReq ← sendGoals goalsDoc { line := 1, character := 2, useAfter := false }
  let goalsAfterReq ← sendGoals goalsDoc { line := 1, character := 2, useAfter := true }

  syncWhitespacePrefixEdit editDoc

  let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsPrevReq
  if goalsPrev.goals.size != 1 then
    throw <| IO.userError s!"goals prev with LSP interference: expected one goal, got {goalsPrev.goals.size}"
  requireSingleGoalTarget "goals prev with LSP interference" "True" goalsPrev

  let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsAfterReq
  if goalsAfter.goals.size != 0 then
    throw <| IO.userError
      s!"goals after with LSP interference: expected solved proof state, got {goalsAfter.goals.size} goals"

  closeDoc goalsDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkGoalsRequests
  checkGoalsRequestsWithStandardLspInterference

end BeamTest.LSP.Requests.Goals.BasicTest
