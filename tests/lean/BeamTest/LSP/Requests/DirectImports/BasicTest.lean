/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.DirectImports
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.DirectImports.BasicTest

private def depAFixture : String :=
  "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"

private def requireDepAImports (label : String)
    (imports : Beam.LSP.DirectImports.DirectImportsResult) : ScenarioM Unit := do
  if imports.version != 1 then
    throw <| IO.userError s!"{label}: expected version 1, got {imports.version}"
  if imports.imports != #["BeamTest.Fixtures.Deps.DepB"] then
    throw <| IO.userError s!"{label}: unexpected imports {(toJson imports.imports).compress}"

def checkDirectImports : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let importsReq ← sendDirectImports doc
  let imports : Beam.LSP.DirectImports.DirectImportsResult ← awaitResponseAs importsReq
  requireDepAImports "directImports" imports

  closeDoc doc

def checkDirectImportsStaleVersion : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let staleReq ← sendDirectImports doc { version? := some 0 }
  expectContentModified staleReq

  closeDoc doc

def checkDirectImportsWithStandardLspInterference : ScenarioM Unit := do
  let importsDoc ← openDoc depAFixture
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let importsReq ← sendDirectImports importsDoc
  syncWhitespacePrefixEdit editDoc

  let imports : Beam.LSP.DirectImports.DirectImportsResult ← awaitResponseAs importsReq
  requireDepAImports "directImports with LSP interference" imports

  closeDoc importsDoc
  closeDoc editDoc

def checkDirectImportsWithMixedConcurrency : ScenarioM Unit := do
  let importsDoc ← openDoc depAFixture
  let slowDoc ← openDoc "tests/scenario/docs/RunWithMixedConcurrencyProof.lean"
  let goalsDoc ← openDoc "tests/save_olean_project/GoalSmoke.lean"
  let cmdDoc ← openDoc "tests/scenario/docs/CommandB.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let slowReqs ← (List.range 3).mapM fun _ =>
    sendRunAt slowDoc { line := 9, character := 2, text := "mixed_sleep_exact" }
  let importsReqs ← (List.range 8).mapM fun _ =>
    sendDirectImports importsDoc
  let goalsPrevReqs ← (List.range 3).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := false }
  let goalsAfterReqs ← (List.range 3).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := true }
  let cmdReqs ← (List.range 6).mapM fun _ =>
    sendRunAt cmdDoc { line := 0, character := 2, text := "#check Nat" }

  syncWhitespacePrefixEdit editDoc

  for req in importsReqs do
    let imports : Beam.LSP.DirectImports.DirectImportsResult ← awaitResponseAs req
    requireDepAImports "directImports mixed concurrency" imports
  for req in goalsPrevReqs do
    let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    if goalsPrev.goals.size != 1 then
      throw <| IO.userError
        s!"directImports mixed concurrency goalsPrev: expected one goal, got {goalsPrev.goals.size}"
    requireSingleGoalTarget "directImports mixed concurrency goalsPrev" "True" goalsPrev
  for req in goalsAfterReqs do
    let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    if goalsAfter.goals.size != 0 then
      throw <| IO.userError
        s!"directImports mixed concurrency goalsAfter: expected solved proof state, got {goalsAfter.goals.size} goals"
  for req in slowReqs do
    discard <| requireRunAtResponseSuccess "directImports mixed concurrency slow runAt" req
  for req in cmdReqs do
    discard <| requireRunAtResponseSuccess "directImports mixed concurrency command runAt" req

  closeDoc importsDoc
  closeDoc slowDoc
  closeDoc goalsDoc
  closeDoc cmdDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkDirectImports
  checkDirectImportsStaleVersion
  checkDirectImportsWithStandardLspInterference
  checkDirectImportsWithMixedConcurrency

end BeamTest.LSP.Requests.DirectImports.BasicTest
