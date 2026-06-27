/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.SyncSummary
import RunAtTest.Broker.JsonAssert
import Lean

open Lean
open Lean.Lsp
open Beam.Broker
open RunAtTest.Broker.JsonAssert

namespace RunAtTest.Broker.SyncSummaryTest

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

private def requireDiagnosticDelta
    (label : String)
    (summary : SyncSummary) : IO SyncDiagnosticDelta := do
  match summary.diagnostics.delta? with
  | some delta => pure delta
  | none => throw <| IO.userError s!"{label}: expected diagnostics.delta"

private def requireReadinessDelta
    (label : String)
    (summary : SyncSummary) : IO SyncReadinessDelta := do
  match summary.readiness.delta? with
  | some delta => pure delta
  | none => throw <| IO.userError s!"{label}: expected readiness.delta"

private def diagnosticMessages (diagnostics : Array Diagnostic) : Array String :=
  diagnostics.map (·.message)

private def checkFirstSyncSummary : IO Unit := do
  let warning := diagnostic 0 0 1 (some .warning) "warning only"
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 1
    saveReady := true
    saveReadyReason := "ok"
  }
  let (summary, record) := mkSyncSummary 1 10 #[warning] readiness none

  require "first sync currentVersion" (summary.currentVersion == 1)
  require "first sync omits deltaBaseVersion" summary.deltaBaseVersion?.isNone
  require "first sync omits diagnostics delta" summary.diagnostics.delta?.isNone
  require "first sync omits readiness delta" summary.readiness.delta?.isNone
  require "first sync records warning count"
    (summary.diagnostics.current.warning == 1 && summary.diagnostics.current.total == 1)
  require "first sync readiness is current verdict"
    (summary.readiness.current.saveReady &&
      summary.readiness.current.warningCount == 1 &&
      summary.readiness.current.saveReadyReason == "ok")
  require "first sync record is reusable as prior summary"
    (record.version == 1 && record.textHash == 10 &&
      diagnosticMessages record.diagnostics == #["warning only"])

private def checkDuplicateDiagnosticDelta : IO Unit := do
  let duplicate := diagnostic 0 0 1 (some .warning) "duplicated warning"
  let added := diagnostic 1 0 1 (some .error) "new error"
  let prior : LastSyncSummary := {
    version := 2
    textHash := 10
    diagnostics := #[duplicate, duplicate]
    readiness := {
      errorCount := 0
      warningCount := 2
      saveReady := true
      saveReadyReason := "ok"
    }
  }
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 1
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence added]
    blockingCommandMessages := #[commandEvidence "new error"]
  }
  let (summary, record) := mkSyncSummary 3 11 #[duplicate, added] readiness (some prior)
  let diagnosticDelta ← requireDiagnosticDelta "duplicate diagnostic delta" summary
  let readinessDelta ← requireReadinessDelta "duplicate diagnostic delta" summary

  require "duplicate diagnostic delta base version" (summary.deltaBaseVersion? == some 2)
  require "duplicate diagnostic delta source changed" summary.sourceChangedSinceDeltaBase
  require "duplicate diagnostic current counts"
    (summary.diagnostics.current.warning == 1 &&
      summary.diagnostics.current.error == 1 &&
      summary.diagnostics.current.total == 2)
  require "duplicate diagnostic bag delta counts"
    (diagnosticDelta.added == 1 &&
      diagnosticDelta.removed == 1 &&
      diagnosticDelta.persisted == 1)
  require "readiness count deltas"
    (readinessDelta.errorCountDelta == (1 : Int) &&
      readinessDelta.warningCountDelta == (-1 : Int))
  require "readiness boolean delta"
    (readinessDelta.saveReadyChanged &&
      readinessDelta.baseSaveReady &&
      !readinessDelta.currentSaveReady)
  require "duplicate diagnostic record updates current state"
    (record.version == 3 && record.textHash == 11 &&
      record.readiness.errorCount == 1 &&
      !record.readiness.saveReady)

private def checkEffectiveSeverityDiagnosticIdentity : IO Unit := do
  let message := "Failed to build module dependencies."
  let priorDiagnostic := diagnostic 0 0 1 none message
  let currentDiagnostic := diagnostic 0 0 1 (some .error) message
  let prior : LastSyncSummary := {
    version := 4
    textHash := 20
    diagnostics := #[priorDiagnostic]
    readiness := {
      errorCount := 1
      saveReady := false
      saveReadyReason := "documentErrors"
    }
  }
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 0
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence currentDiagnostic]
  }
  let (summary, _) := mkSyncSummary 5 20 #[currentDiagnostic] readiness (some prior)
  let delta ← requireDiagnosticDelta "effective severity diagnostic identity" summary

  require "effective severity counts incomplete-barrier diagnostic as error"
    (summary.diagnostics.current.error == 1 &&
      summary.diagnostics.current.unknown == 0)
  require "effective severity is part of diagnostic identity"
    (delta.added == 0 && delta.removed == 0 && delta.persisted == 1)
  require "same text hash reports unchanged source" (!summary.sourceChangedSinceDeltaBase)

private def checkDiagnosticErrorsDoNotOverrideReadiness : IO Unit := do
  let interactiveDiagnostic := diagnostic 0 0 1 (some .error) "interactive-only diagnostic"
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 0
    saveReady := true
    saveReadyReason := "ok"
  }
  let (summary, record) := mkSyncSummary 6 25 #[interactiveDiagnostic] readiness none

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
  require "summary record preserves Lean save-readiness verdict"
    (record.readiness.errorCount == 0 &&
      record.readiness.saveReady)

private def checkSaveBlockingEvidenceProjection : IO Unit := do
  let blockingDiagnostic := diagnostic 0 0 1 (some .error) "save-blocking diagnostic"
  let readiness : SyncSaveReadiness := {
    currentWarningCount? := some 0
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence blockingDiagnostic]
    blockingCommandMessages := #[commandEvidence "save-blocking command message"]
  }
  let (summary, record) := mkSyncSummary 7 28 #[blockingDiagnostic] readiness none

  require "save-blocking evidence appears in readiness summary"
    (summary.readiness.current.blockingDiagnostics.size == 1 &&
      summary.readiness.current.blockingDiagnostics[0]?.map (·.saveBlocking) == some true &&
      summary.readiness.current.blockingCommandMessages.size == 1 &&
      summary.readiness.current.blockingCommandMessages[0]?.map (·.saveBlocking) == some true)
  require "save-blocking evidence is retained for delta baseline"
    (record.readiness.blockingDiagnostics.size == 1 &&
      record.readiness.blockingCommandMessages.size == 1)

private def checkCurrentSyncDiagnosticsFallback : IO Unit := do
  let priorDiagnostic := diagnostic 0 0 1 (some .error) "prior error"
  let freshDiagnostic := diagnostic 1 0 1 (some .error) "fresh error"
  let prior : LastSyncSummary := {
    version := 7
    textHash := 30
    diagnostics := #[priorDiagnostic]
    readiness := {
      errorCount := 1
      saveReady := false
      saveReadyReason := "documentErrors"
    }
  }

  require "unseen unchanged sync reuses prior diagnostics"
    (diagnosticMessages (currentSyncDiagnostics 7 #[] false (some prior)) == #["prior error"])
  require "seen unchanged sync can clear diagnostics"
    (diagnosticMessages (currentSyncDiagnostics 7 #[] true (some prior)) == #[])
  require "unseen changed sync uses current diagnostics"
    (diagnosticMessages (currentSyncDiagnostics 8 #[freshDiagnostic] false (some prior)) ==
      #["fresh error"])
  require "no prior sync uses current diagnostics"
    (diagnosticMessages (currentSyncDiagnostics 1 #[freshDiagnostic] false none) ==
      #["fresh error"])

def main : IO Unit := do
  checkFirstSyncSummary
  checkDuplicateDiagnosticDelta
  checkEffectiveSeverityDiagnosticIdentity
  checkDiagnosticErrorsDoNotOverrideReadiness
  checkSaveBlockingEvidenceProjection
  checkCurrentSyncDiagnosticsFallback

end RunAtTest.Broker.SyncSummaryTest

def main := RunAtTest.Broker.SyncSummaryTest.main
