/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.BasicTest

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

def checkRunAtOneCommandOnly : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt command sequence" doc { line := 8, character := 0 }
    "def runAtOneCommandA : Nat := 1\n\n#check runAtOneCommandA"
    "runAtSupportsOneCommandOnly"
  closeDoc doc

def checkRunAtTheoremProofFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem proof failure" doc { line := 8, character := 0 }
    "theorem runAtImpossibleProbe : False := by\n  trivial"
    "False"
  closeDoc doc

def checkRunAtTheoremTacticFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TopLevelTheoremRunAtFailure.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem tactic failure" doc { line := 7, character := 0 }
    "theorem runAtTacticFailureProbe : True := by\n  runat_fail_tac"
    "runAt custom tactic failure"
  closeDoc doc

def checkRunAtInvalidPositionLine : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/CommandA.lean"

  let req ← sendRunAt doc { line := 99, character := 0, text := "#check Nat" }

  expectErrorContains req invalidParamsJson

  closeDoc doc

def checkRunAtInvalidPositionCharacter : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/CommandA.lean"

  let req ← sendRunAt doc { line := 0, character := 200, text := "#check Nat" }

  expectErrorContains req invalidParamsJson

  closeDoc doc

def checkRunAtStaleVersion : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  syncDoc doc

  let staleReq ← sendRunAt doc {
    version? := some 0
    line := 1
    character := 2
    text := "exact trivial"
  }
  expectContentModified staleReq

  closeDoc doc

def checkRunAtStaleEditConcurrentRequest : ScenarioM Unit := do
  let staleDoc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let survivorDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let staleReq ← sendRunAt staleDoc { line := 1, character := 2, text := "exact trivial" }
  let survivorReq ← sendRunAt survivorDoc { line := 1, character := 2, text := "exact trivial" }

  invalidateWithWhitespacePrefixEdit staleDoc

  expectContentModified staleReq
  discard <| requireRunAtResponseSuccess "runAt concurrent request after stale edit" survivorReq

  closeDoc staleDoc
  closeDoc survivorDoc

def checkRunAtWithStandardLspInterference : ScenarioM Unit := do
  let runAtDoc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let runAtReq ← sendRunAt runAtDoc { line := 1, character := 2, text := "exact trivial" }
  syncWhitespacePrefixEdit editDoc

  discard <| requireRunAtResponseSuccess "runAt with LSP interference" runAtReq

  closeDoc runAtDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkRunAtOneCommandOnly
  checkRunAtTheoremProofFailure
  checkRunAtTheoremTacticFailure
  checkRunAtInvalidPositionLine
  checkRunAtInvalidPositionCharacter
  checkRunAtStaleVersion
  checkRunAtStaleEditConcurrentRequest
  checkRunAtWithStandardLspInterference

end BeamTest.LSP.Requests.RunAt.BasicTest
