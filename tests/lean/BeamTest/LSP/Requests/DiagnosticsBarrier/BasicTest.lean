/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.DiagnosticsBarrier
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference

namespace BeamTest.LSP.Requests.DiagnosticsBarrier.BasicTest

private def depAFixture : System.FilePath :=
  "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"

def requireDepAResult (label : String) (result : Beam.LSP.DiagnosticsBarrier.Result) :
    ScenarioM Unit := do
  let expectedTextHash := hash (← IO.FS.readFile depAFixture)
  if result.version != 1 then
    throw <| IO.userError s!"{label}: expected version 1, got {result.version}"
  if result.directImports != #["BeamTest.Fixtures.Deps.DepB"] then
    throw <| IO.userError
      s!"{label}: unexpected imports {(toJson result.directImports).compress}"
  if result.saveReadiness.version != 1 then
    throw <| IO.userError
      s!"{label}: expected readiness version 1, got {result.saveReadiness.version}"
  if result.saveReadiness.textHash != expectedTextHash then
    throw <| IO.userError <|
      s!"{label}: expected readiness text hash {expectedTextHash}, " ++
        s!"got {result.saveReadiness.textHash}"
  if !result.saveReadiness.saveReady then
    throw <| IO.userError
      s!"{label}: expected saveReady=true, got {(toJson result.saveReadiness).compress}"
  if result.saveReadiness.saveReadyReason != "ok" then
    throw <| IO.userError
      s!"{label}: expected saveReadyReason=ok, got {result.saveReadiness.saveReadyReason}"

def checkDiagnosticsBarrier : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let barrierReq ← sendDiagnosticsBarrier doc
  let result : Beam.LSP.DiagnosticsBarrier.Result ← awaitResponseAs barrierReq
  requireDepAResult "diagnosticsBarrier" result

  closeDoc doc

def checkDiagnosticsBarrierAcceptsSatisfiedVersion : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let barrierReq ← sendDiagnosticsBarrier doc { version? := some 0 }
  let result : Beam.LSP.DiagnosticsBarrier.Result ← awaitResponseAs barrierReq
  requireDepAResult "diagnosticsBarrier satisfied version" result

  closeDoc doc

def checkDiagnosticsBarrierWithStandardLspInterference : ScenarioM Unit := do
  let barrierDoc ← openDoc depAFixture
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let barrierReq ← sendDiagnosticsBarrier barrierDoc
  syncWhitespacePrefixEdit editDoc

  let result : Beam.LSP.DiagnosticsBarrier.Result ← awaitResponseAs barrierReq
  requireDepAResult "diagnosticsBarrier with LSP interference" result

  closeDoc barrierDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkDiagnosticsBarrier
  checkDiagnosticsBarrierAcceptsSatisfiedVersion
  checkDiagnosticsBarrierWithStandardLspInterference

end BeamTest.LSP.Requests.DiagnosticsBarrier.BasicTest
