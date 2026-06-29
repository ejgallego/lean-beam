/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Support

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

def run : ScenarioM Unit := do
  checkGoalsRequests

end BeamTest.LSP.Requests.Goals.BasicTest
