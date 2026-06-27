/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.DocumentState
import Beam.Broker.Protocol
import Beam.Broker.SyncSaveSupport

open Lean
open Lean.Lsp

namespace Beam.Broker

private def diagnosticCounts (diagnostics : Array Diagnostic) : SyncDiagnosticCounts :=
  diagnostics.foldl (init := {}) fun counts diagnostic =>
    let counts := { counts with total := counts.total + 1 }
    match effectiveSyncDiagnosticSeverity diagnostic with
    | some .error => { counts with error := counts.error + 1 }
    | some .warning => { counts with warning := counts.warning + 1 }
    | some .information => { counts with information := counts.information + 1 }
    | some .hint => { counts with hint := counts.hint + 1 }
    | none => { counts with unknown := counts.unknown + 1 }

private def diagnosticKey (diagnostic : Diagnostic) : String :=
  (Json.mkObj [
    ("range", toJson diagnostic.fullRange),
    ("severity", toJson (effectiveSyncDiagnosticSeverity diagnostic)),
    ("message", toJson diagnostic.message)
  ]).compress

private abbrev DiagnosticBag :=
  Std.TreeMap String Nat

private def diagnosticBag (diagnostics : Array Diagnostic) : DiagnosticBag :=
  diagnostics.foldl (init := {}) fun bag diagnostic =>
    let key := diagnosticKey diagnostic
    bag.insert key ((bag.get? key).getD 0 + 1)

private def bagDifferenceCount (left right : DiagnosticBag) : Nat :=
  left.foldl (init := 0) fun count key leftCount =>
    count + (leftCount - min leftCount ((right.get? key).getD 0))

private def bagIntersectionCount (left right : DiagnosticBag) : Nat :=
  left.foldl (init := 0) fun count key leftCount =>
    count + min leftCount ((right.get? key).getD 0)

private def diagnosticDelta
    (base : LastSyncSummary)
    (currentDiagnostics : Array Diagnostic) : SyncDiagnosticDelta :=
  let baseBag := diagnosticBag base.diagnostics
  let currentBag := diagnosticBag currentDiagnostics
  {
    added := bagDifferenceCount currentBag baseBag
    removed := bagDifferenceCount baseBag currentBag
    persisted := bagIntersectionCount currentBag baseBag
  }

private def natDelta (base current : Nat) : Int :=
  Int.ofNat current - Int.ofNat base

/--
Compute readiness `errorCount` from save-blocking evidence, falling back to diagnostic errors only
when a non-ready verdict did not provide evidence.
-/
private def evidenceErrorCount
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : Nat :=
  if readiness.saveReady then
    0
  else
    let diagnosticCount :=
      readiness.blockingDiagnostics.foldl (init := 0) fun count diagnostic =>
        if diagnostic.saveBlocking then count + 1 else count
    let commandCount :=
      readiness.blockingCommandMessages.foldl (init := 0) fun count message =>
        if message.saveBlocking then count + 1 else count
    if diagnosticCount > 0 then
      diagnosticCount
    else if commandCount > 0 then
      commandCount
    else
      syncErrorCount diagnostics

def syncReadinessCurrent
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : SyncReadinessCurrent :=
  {
    errorCount := evidenceErrorCount diagnostics readiness
    warningCount := readiness.currentWarningCount?.getD (syncWarningCount diagnostics)
    saveReady := readiness.saveReady
    saveReadyReason := readiness.saveReadyReason
    blockingDiagnostics := readiness.blockingDiagnostics
    blockingCommandMessages := readiness.blockingCommandMessages
  }

private def readinessDelta
    (base : LastSyncSummary)
    (current : SyncReadinessCurrent) : SyncReadinessDelta :=
  {
    errorCountDelta :=
      natDelta base.readiness.errorCount current.errorCount
    warningCountDelta := natDelta base.readiness.warningCount current.warningCount
    saveReadyChanged := base.readiness.saveReady != current.saveReady
    baseSaveReady := base.readiness.saveReady
    currentSaveReady := current.saveReady
  }

def mkSyncSummary
    (version : Nat)
    (textHash : UInt64)
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness)
    (prior? : Option LastSyncSummary) : SyncSummary × LastSyncSummary :=
  let readiness := normalizeSyncSaveReadiness diagnostics readiness
  let currentReadiness := syncReadinessCurrent diagnostics readiness
  let summary : SyncSummary := {
    currentVersion := version
    deltaBaseVersion? := prior?.map (·.version)
    sourceChangedSinceDeltaBase :=
      prior?.map (fun prior => prior.textHash != textHash) |>.getD false
    diagnostics := {
      current := diagnosticCounts diagnostics
      delta? := prior?.map (fun prior => diagnosticDelta prior diagnostics)
    }
    readiness := {
      current := currentReadiness
      delta? := prior?.map (fun prior => readinessDelta prior currentReadiness)
    }
  }
  let record : LastSyncSummary := {
    version
    textHash
    diagnostics
    readiness := currentReadiness
  }
  (summary, record)

end Beam.Broker
