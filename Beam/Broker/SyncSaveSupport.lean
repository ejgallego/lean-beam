/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import RunAt.Internal.SaveSupport
import Beam.Broker.LakeSave
import Beam.Broker.Protocol

open Lean
open Lean.Lsp

namespace Beam.Broker

def isIncompleteBarrierDiagnostic (diagnostic : Diagnostic) : Bool :=
  diagnostic.message.contains "Failed to build module dependencies." ||
    diagnostic.message.contains "error: target is out-of-date and needs to be rebuilt"

def effectiveSyncDiagnosticSeverity (diagnostic : Diagnostic) :
    Option DiagnosticSeverity :=
  if isIncompleteBarrierDiagnostic diagnostic then
    some .error
  else
    diagnostic.severity?

def isSyncErrorDiagnostic (diagnostic : Diagnostic) : Bool :=
  match effectiveSyncDiagnosticSeverity diagnostic with
  | some .error => true
  | _ => false

def isSyncWarningDiagnostic (diagnostic : Diagnostic) : Bool :=
  match effectiveSyncDiagnosticSeverity diagnostic with
  | some .warning => true
  | _ => false

def filterSyncDiagnostics (fullDiagnostics : Bool) (diagnostics : Array Diagnostic) :
    Array Diagnostic :=
  if fullDiagnostics then
    diagnostics
  else
    diagnostics.filter isSyncErrorDiagnostic

def diagnosticDisplayPath (root : System.FilePath) (uri : DocumentUri) : String :=
  match System.Uri.fileUriToPath? uri with
  | some path =>
      let rootStr := root.toString
      let pathStr := path.toString
      let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
      if pathStr.startsWith rootPrefix then
        (pathStr.drop rootPrefix.length).toString
      else if pathStr == rootStr then
        "."
      else
        pathStr
  | none =>
      uri

def streamDiagnosticOfDiagnostic
    (root : System.FilePath)
    (uri : DocumentUri)
    (version? : Option Int)
    (diagnostic : Diagnostic) : StreamDiagnostic := {
  path := diagnosticDisplayPath root uri
  uri
  version?
  severity? := effectiveSyncDiagnosticSeverity diagnostic
  range := diagnostic.fullRange
  message := diagnostic.message
  completionBlocking := isIncompleteBarrierDiagnostic diagnostic
}

def streamDiagnosticsForReply
    (root : System.FilePath)
    (uri : DocumentUri)
    (version : Nat)
    (fullDiagnostics : Bool)
    (diagnostics : Array Diagnostic) : Array StreamDiagnostic :=
  (filterSyncDiagnostics fullDiagnostics diagnostics).map fun diagnostic =>
    streamDiagnosticOfDiagnostic root uri (some (Int.ofNat version)) diagnostic

def syncErrorCount (diagnostics : Array Diagnostic) : Nat :=
  diagnostics.foldl (init := 0) fun count diagnostic =>
    if isSyncErrorDiagnostic diagnostic then
      count + 1
    else
      count

def syncWarningCount (diagnostics : Array Diagnostic) : Nat :=
  diagnostics.foldl (init := 0) fun count diagnostic =>
    if isSyncWarningDiagnostic diagnostic then
      count + 1
    else
      count

structure SyncSaveReadiness where
  currentSaveBlockingErrorCount? : Option Nat := none
  currentWarningCount? : Option Nat := none
  stateErrorCount : Nat := 0
  stateCommandErrorCount : Nat := 0
  saveReady : Bool := true
  saveReadyReason : String := "ok"
  saveReadyMessage? : Option String := none
  blockingDiagnostics : Array SyncBlockingDiagnostic := #[]
  blockingCommandMessages : Array SyncBlockingCommandMessage := #[]
  deriving Inhabited

private def syncBlockingDiagnosticOfResult
    (diagnostic : RunAt.Internal.SaveBlockingDiagnostic) : SyncBlockingDiagnostic := {
  range := diagnostic.range
  severity? := diagnostic.severity?
  message := diagnostic.message
  saveBlocking := diagnostic.saveBlocking
  completionBlocking := diagnostic.completionBlocking
}

private def syncBlockingCommandMessageOfResult
    (message : RunAt.Internal.SaveBlockingCommandMessage) : SyncBlockingCommandMessage := {
  message := message.message
  saveBlocking := message.saveBlocking
  completionBlocking := message.completionBlocking
}

def syncSaveReadinessOfResult
    (result : RunAt.Internal.SaveReadinessResult) : SyncSaveReadiness :=
  {
    currentSaveBlockingErrorCount? := some result.saveBlockingErrorCount
    currentWarningCount? := some result.currentWarningCount
    stateErrorCount := result.saveBlockingErrorCount
    stateCommandErrorCount := result.commandErrorCount
    saveReady := result.saveReady
    saveReadyReason := result.saveReadyReason
    saveReadyMessage? := result.saveReadyMessage?
    blockingDiagnostics := result.blockingDiagnostics.map syncBlockingDiagnosticOfResult
    blockingCommandMessages := result.blockingCommandMessages.map syncBlockingCommandMessageOfResult
  }

def syncBlockingDiagnosticOfDiagnostic
    (saveBlocking completionBlocking : Bool)
    (diagnostic : Diagnostic) : SyncBlockingDiagnostic := {
  range := diagnostic.fullRange
  severity? := effectiveSyncDiagnosticSeverity diagnostic
  message := diagnostic.message
  saveBlocking
  completionBlocking
}

def completionBlockingDiagnostics (diagnostics : Array Diagnostic) : Array SyncBlockingDiagnostic :=
  diagnostics.filterMap fun diagnostic =>
    if isIncompleteBarrierDiagnostic diagnostic then
      some <| syncBlockingDiagnosticOfDiagnostic false true diagnostic
    else
      none

def saveBlockingFallbackDiagnostics (diagnostics : Array Diagnostic) : Array SyncBlockingDiagnostic :=
  diagnostics.filterMap fun diagnostic =>
    if isSyncErrorDiagnostic diagnostic then
      some <| syncBlockingDiagnosticOfDiagnostic true false diagnostic
    else
      none

def withFallbackSaveBlockingEvidence
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : SyncSaveReadiness :=
  if readiness.saveReady ||
      !readiness.blockingDiagnostics.isEmpty ||
      !readiness.blockingCommandMessages.isEmpty then
    readiness
  else
    { readiness with blockingDiagnostics := saveBlockingFallbackDiagnostics diagnostics }

def diagnosticsIndicateIncompleteBarrier (diagnostics : Array Diagnostic) : Bool :=
  diagnostics.any isIncompleteBarrierDiagnostic

def incompleteBarrierProgress (progress? : Option SyncFileProgress := none) : SyncFileProgress :=
  match progress? with
  | some progress => { progress with done := false }
  | none => { done := false }

def syncBarrierIncompleteMessage
    (uri : DocumentUri)
    (version : Nat)
    (progress? : Option SyncFileProgress) : String :=
  let progress := incompleteBarrierProgress progress?
  s!"Lean diagnostics barrier did not complete for {uri} at version {version}; " ++
    s!"fileProgress={toJson progress |>.compress}. An imported target may be stale or broken, " ++
    s!"or the Lean worker may have exited. Run `lake build` or fix the upstream module first."

def syncBarrierIncomplete?
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic := #[]) : Bool :=
  if diagnosticsIndicateIncompleteBarrier diagnostics then
    true
  else
    match progress? with
    | some progress => !progress.done
    | none => false

def effectiveSyncBarrierProgress
    (priorProgress? : Option SyncFileProgress)
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic) : Option SyncFileProgress :=
  if diagnosticsIndicateIncompleteBarrier diagnostics then
    some <| incompleteBarrierProgress (progress?.or priorProgress?)
  else
    match progress? with
    | some progress =>
        some progress
    | none =>
        some <| priorProgress?.getD {}

def leanSavePayload (spec : LeanSaveSpec) (version : Nat) (sourceHash : Lake.Hash) : Json :=
  Json.mkObj <|
    [
      ("path", toJson spec.relPath),
      ("module", toJson spec.moduleName.toString),
      ("version", toJson version),
      ("sourceHash", toJson sourceHash),
      ("olean", toJson spec.oleanPath.toString),
      ("ilean", toJson spec.ileanPath.toString),
      ("c", toJson spec.cPath.toString),
      ("trace", toJson spec.tracePath.toString)
    ] ++
    (match spec.oleanServerPath? with
    | some path => [("oleanServer", toJson path.toString)]
    | none => []) ++
    (match spec.oleanPrivatePath? with
    | some path => [("oleanPrivate", toJson path.toString)]
    | none => []) ++
    (match spec.irPath? with
    | some path => [("ir", toJson path.toString)]
    | none => []) ++
    (match spec.bcPath? with
    | some path => [("bc", toJson path.toString)]
    | none => [])

end Beam.Broker
