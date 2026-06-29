/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.SyncSummary
import BeamTest.Broker.JsonAssert
import Lean

open Lean
open Lean.Lsp
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.SyncSummaryTest

private def lspPos (line character : Nat) : Lsp.Position :=
  { line, character }

private def lspRange (line startCharacter endCharacter : Nat) : Lsp.Range :=
  { start := lspPos line startCharacter, «end» := lspPos line endCharacter }

private def diagnostic
    (line startCharacter endCharacter : Nat)
    (severity? : Option DiagnosticSeverity)
    (message : String) : Diagnostic :=
  let range := lspRange line startCharacter endCharacter
  {
    range
    fullRange? := some range
    severity?
    message
  }

private def blockingEvidence (diagnostic : Diagnostic) : SyncBlockingDiagnostic := {
  range := diagnostic.fullRange
  severity? := diagnostic.severity?
  message := diagnostic.message
  saveBlocking := true
  completionBlocking := false
}

private def commandEvidence (message : String) : SyncBlockingCommandMessage := {
  message
  saveBlocking := true
  completionBlocking := false
}

private def checkFirstSyncSummary : IO Unit := do
  let warning := diagnostic 0 0 1 (some .warning) "warning only"
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 1
    saveReady := true
    saveReadyReason := "ok"
  }
  let summary := mkSyncSummary 1 #[warning] readiness

  require "first sync currentVersion" (summary.currentVersion == 1)
  require "first sync records warning count"
    (summary.diagnostics.current.warning == 1 && summary.diagnostics.current.total == 1)
  require "first sync readiness is current verdict"
    (summary.readiness.current.saveReady &&
      summary.readiness.current.warningCount == 1 &&
      summary.readiness.current.saveReadyReason == "ok")

private def checkCurrentCountsAndReadinessEvidence : IO Unit := do
  let duplicate := diagnostic 0 0 1 (some .warning) "duplicated warning"
  let added := diagnostic 1 0 1 (some .error) "new error"
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 1
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence added]
    blockingCommandMessages := #[commandEvidence "new error"]
  }
  let summary := mkSyncSummary 3 #[duplicate, duplicate, added] readiness

  require "duplicate diagnostic current counts"
    (summary.diagnostics.current.warning == 2 &&
      summary.diagnostics.current.error == 1 &&
      summary.diagnostics.current.total == 3)
  require "readiness current verdict reflects blocking evidence"
    (summary.readiness.current.errorCount == 1 &&
      summary.readiness.current.blockingDiagnostics.size == 1 &&
      summary.readiness.current.blockingCommandMessages.size == 1 &&
      !summary.readiness.current.saveReady)

private def checkEffectiveSeverityCounts : IO Unit := do
  let message := "Failed to build module dependencies."
  let currentDiagnostic := diagnostic 0 0 1 (some .error) message
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 0
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence currentDiagnostic]
  }
  let summary := mkSyncSummary 5 #[currentDiagnostic] readiness

  require "effective severity counts incomplete-barrier diagnostic as error"
    (summary.diagnostics.current.error == 1 &&
      summary.diagnostics.current.unknown == 0)

private def checkDiagnosticErrorsDoNotOverrideReadiness : IO Unit := do
  let interactiveDiagnostic := diagnostic 0 0 1 (some .error) "interactive-only diagnostic"
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 0
    saveReady := true
    saveReadyReason := "ok"
  }
  let summary := mkSyncSummary 6 #[interactiveDiagnostic] readiness

  require "diagnostic severity counts report current Lean diagnostics"
    (summary.diagnostics.current.error == 1 &&
      summary.diagnostics.current.total == 1)
  require "diagnostics do not override Lean save-readiness"
    (summary.readiness.current.errorCount == 0 &&
      summary.readiness.current.saveReady &&
      summary.readiness.current.saveReadyReason == "ok")
  require "summary does not synthesize save-blocking evidence while Lean is ready"
    (summary.readiness.current.blockingDiagnostics.isEmpty &&
      summary.readiness.current.blockingCommandMessages.isEmpty)

private def checkSaveBlockingEvidenceProjection : IO Unit := do
  let blockingDiagnostic := diagnostic 0 0 1 (some .error) "save-blocking diagnostic"
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 0
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence blockingDiagnostic]
    blockingCommandMessages := #[commandEvidence "save-blocking command message"]
  }
  let summary := mkSyncSummary 7 #[blockingDiagnostic] readiness

  require "save-blocking evidence appears in readiness summary"
    (summary.readiness.current.blockingDiagnostics.size == 1 &&
      summary.readiness.current.blockingDiagnostics[0]?.map (·.saveBlocking) == some true &&
      summary.readiness.current.blockingCommandMessages.size == 1 &&
      summary.readiness.current.blockingCommandMessages[0]?.map (·.saveBlocking) == some true)

def main : IO Unit := do
  checkFirstSyncSummary
  checkCurrentCountsAndReadinessEvidence
  checkEffectiveSeverityCounts
  checkDiagnosticErrorsDoNotOverrideReadiness
  checkSaveBlockingEvidenceProjection

end BeamTest.Broker.SyncSummaryTest

def main := BeamTest.Broker.SyncSummaryTest.main
