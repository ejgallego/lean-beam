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
    (currentVersion : Nat)
    (currentDiagnostics : Array Diagnostic) : SyncDiagnosticDelta :=
  let baseBag := diagnosticBag base.diagnostics
  let currentBag := diagnosticBag currentDiagnostics
  {
    baseVersion := base.version
    currentVersion
    added := bagDifferenceCount currentBag baseBag
    removed := bagDifferenceCount baseBag currentBag
    persisted := bagIntersectionCount currentBag baseBag
  }

private def natDelta (base current : Nat) : Int :=
  Int.ofNat current - Int.ofNat base

def syncReadinessCurrent
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : SyncReadinessCurrent :=
  {
    saveBlockingErrorCount := readiness.currentSaveBlockingErrorCount?.getD (syncErrorCount diagnostics)
    warningCount := readiness.currentWarningCount?.getD (syncWarningCount diagnostics)
    commandErrorCount := readiness.stateCommandErrorCount
    saveReady := readiness.saveReady
    saveReadyReason := readiness.saveReadyReason
    blockingDiagnostics := readiness.blockingDiagnostics
    blockingCommandMessages := readiness.blockingCommandMessages
  }

private def readinessDelta
    (base : LastSyncSummary)
    (currentVersion : Nat)
    (current : SyncReadinessCurrent) : SyncReadinessDelta :=
  {
    baseVersion := base.version
    currentVersion
    saveBlockingErrorCountDelta :=
      natDelta base.readiness.saveBlockingErrorCount current.saveBlockingErrorCount
    warningCountDelta := natDelta base.readiness.warningCount current.warningCount
    commandErrorCountDelta :=
      natDelta base.readiness.commandErrorCount current.commandErrorCount
    saveReadyChanged := base.readiness.saveReady != current.saveReady
    baseSaveReady := base.readiness.saveReady
    currentSaveReady := current.saveReady
  }

def currentSyncDiagnostics
    (version : Nat)
    (diagnostics : Array Diagnostic)
    (diagnosticsSeen : Bool)
    (prior? : Option LastSyncSummary) : Array Diagnostic :=
  if diagnosticsSeen then
    diagnostics
  else
    match prior? with
    | some prior =>
        if prior.version == version then prior.diagnostics else diagnostics
    | none =>
        diagnostics

def mkSyncSummary
    (version : Nat)
    (textHash : UInt64)
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness)
    (prior? : Option LastSyncSummary) : SyncSummary × LastSyncSummary :=
  let currentReadiness := syncReadinessCurrent diagnostics readiness
  let summary : SyncSummary := {
    currentVersion := version
    deltaBaseVersion? := prior?.map (·.version)
    sourceChangedSinceDeltaBase :=
      prior?.map (fun prior => prior.textHash != textHash) |>.getD false
    diagnostics := {
      current := diagnosticCounts diagnostics
      delta? := prior?.map (fun prior => diagnosticDelta prior version diagnostics)
    }
    readiness := {
      current := currentReadiness
      delta? := prior?.map (fun prior => readinessDelta prior version currentReadiness)
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
