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

def mkSyncSummary
    (version : Nat)
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : SyncSummary :=
  let readiness := normalizeSyncSaveReadiness diagnostics readiness
  let currentReadiness := syncReadinessCurrent diagnostics readiness
  {
    currentVersion := version
    diagnostics := {
      current := diagnosticCounts diagnostics
    }
    readiness := {
      current := currentReadiness
    }
  }

end Beam.Broker
