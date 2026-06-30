/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.Save
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.Save.BasicTest

def checkSaveArtifactsAndReadiness : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"

  let readinessReq ← sendSaveReadiness doc
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError s!"saveReadiness: expected saveReady = true, got {(toJson readiness).compress}"
  if readiness.saveReadyReason != "ok" then
    throw <| IO.userError s!"saveReadiness: expected reason = ok, got {readiness.saveReadyReason}"
  unless readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty do
    throw <| IO.userError
      s!"saveReadiness: expected clean file to omit save-blocking evidence, got {(toJson readiness).compress}"

  let staleReadinessVersionReq ← sendSaveReadiness doc {
    expectedVersionOverride? := some 0
  }
  expectErrorContains staleReadinessVersionReq (Json.mkObj [("code", toJson "contentModified")])

  let depAText ← IO.FS.readFile "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  let staleTextHash := if hash depAText == 0 then 1 else 0
  let staleReadinessHashReq ← sendSaveReadiness doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some staleTextHash
  }
  expectErrorContains staleReadinessHashReq (Json.mkObj [("code", toJson "contentModified")])

  let outDir ← mkTmpDir "beam-save-request-surface"
  let staleVersionReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 0
    oleanFile := (outDir / "StaleVersion.olean").toString
    ileanFile := (outDir / "StaleVersion.ilean").toString
    cFile := (outDir / "StaleVersion.c").toString
  }
  expectErrorContains staleVersionReq (Json.mkObj [("code", toJson "contentModified")])

  let staleHashReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some staleTextHash
    oleanFile := (outDir / "StaleHash.olean").toString
    ileanFile := (outDir / "StaleHash.ilean").toString
    cFile := (outDir / "StaleHash.c").toString
  }
  expectErrorContains staleHashReq (Json.mkObj [("code", toJson "contentModified")])

  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash depAText)
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }
  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs saveReq
  if !saved.written then
    throw <| IO.userError "saveArtifacts: expected written = true"
  if saved.version != 1 then
    throw <| IO.userError s!"saveArtifacts: expected version 1, got {saved.version}"
  expectFileExists "saveArtifacts olean" (outDir / "DepA.olean")
  expectFileExists "saveArtifacts ilean" (outDir / "DepA.ilean")
  expectFileExists "saveArtifacts c" (outDir / "DepA.c")

  changeDoc doc {
    line := 8
    character := 18
    delete := "depB"
    insert := "\"oops\""
  }
  syncDoc doc

  let brokenReq ← sendSaveReadiness doc
  let broken : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs brokenReq
  if broken.saveReady then
    throw <| IO.userError s!"broken saveReadiness: expected saveReady = false, got {(toJson broken).compress}"
  if broken.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"broken saveReadiness: expected reason = documentErrors, got {broken.saveReadyReason}"
  if broken.blockingDiagnostics.isEmpty && broken.blockingCommandMessages.isEmpty then
    throw <| IO.userError
      s!"broken saveReadiness: expected save-blocking evidence, got {(toJson broken).compress}"
  unless broken.blockingDiagnostics.all (·.saveBlocking) &&
      broken.blockingCommandMessages.all (·.saveBlocking) do
    throw <| IO.userError
      s!"broken saveReadiness: expected blocking evidence to carry saveBlocking=true, got {(toJson broken).compress}"

  closeDoc doc

def checkSaveRequestsWithStandardLspInterference : ScenarioM Unit := do
  let saveDoc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let depAText ← IO.FS.readFile "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  let outDir ← mkTmpDir "beam-save-lsp-interference"

  let readinessReq ← sendSaveReadiness saveDoc
  let saveReq ← sendSaveArtifacts saveDoc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash depAText)
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }

  syncWhitespacePrefixEdit editDoc

  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError
      s!"saveReadiness with LSP interference: expected saveReady = true, got {(toJson readiness).compress}"
  if readiness.saveReadyReason != "ok" then
    throw <| IO.userError
      s!"saveReadiness with LSP interference: expected reason = ok, got {readiness.saveReadyReason}"

  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs saveReq
  if !saved.written then
    throw <| IO.userError "saveArtifacts with LSP interference: expected written = true"
  if saved.version != 1 then
    throw <| IO.userError s!"saveArtifacts with LSP interference: expected version 1, got {saved.version}"
  expectFileExists "saveArtifacts with LSP interference olean" (outDir / "DepA.olean")
  expectFileExists "saveArtifacts with LSP interference ilean" (outDir / "DepA.ilean")
  expectFileExists "saveArtifacts with LSP interference c" (outDir / "DepA.c")

  closeDoc saveDoc
  closeDoc editDoc

def checkReportedOnlyErrorReadiness : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/ReportedOnlyError.lean"
  syncDoc doc

  let readinessReq ← sendSaveReadiness doc
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError
      s!"reported-only saveReadiness: expected saveReady = true, got {(toJson readiness).compress}"
  unless readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty do
    throw <| IO.userError
      s!"reported-only saveReadiness: expected no save-blocking evidence, got {(toJson readiness).compress}"

  closeDoc doc

def run : ScenarioM Unit := do
  checkSaveArtifactsAndReadiness
  checkSaveRequestsWithStandardLspInterference
  checkReportedOnlyErrorReadiness

end BeamTest.LSP.Requests.Save.BasicTest
