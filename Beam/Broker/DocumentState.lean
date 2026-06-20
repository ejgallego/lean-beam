/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake
import Lean
import Beam.Broker.Protocol

open Lean
open Lean.Lsp

namespace Beam.Broker

structure LastSyncSummary where
  version : Nat
  textHash : UInt64
  diagnostics : Array Diagnostic := #[]
  readiness : SyncReadinessCurrent := {}

structure DocState where
  version : Nat
  textHash : UInt64
  textTraceHash : Lake.Hash
  textMTime : Lake.MTime
  -- File contents may be read before the broker state mutex is held. This
  -- records the newest ordered request snapshot applied to the LSP document.
  syncSnapshotSeq : Nat := 0
  moduleName? : Option String := none
  savedOleanVersion? : Option Nat := none
  fileProgress? : Option SyncFileProgress := none
  lastSyncSeq : Nat := 0
  lastSaveSeq : Nat := 0
  lastSyncSummary? : Option LastSyncSummary := none

structure ModuleHistory where
  path : String
  lastSyncSeq : Nat := 0
  lastSaveSeq : Nat := 0

namespace DocumentState

abbrev Docs := Std.TreeMap String DocState

abbrev ModuleHistories := Std.TreeMap String ModuleHistory

structure ModuleHistorySnapshot where
  path : String
  lastSyncSeq : Nat := 0
  lastSaveSeq : Nat := 0
  deriving Inhabited

structure FileSnapshot where
  textHash : UInt64
  textTraceHash : Lake.Hash
  textMTime : Lake.MTime
  /-- Zero means legacy/in-session sync with no cross-request ordering token. -/
  readSeq : Nat := 0
  moduleName? : Option String := none

inductive SyncFileAction where
  | open
  | change
  | unchanged
  deriving Inhabited, BEq, Repr

structure SyncFileDecision where
  action : SyncFileAction
  version : Nat
  docs : Docs

structure VersionMarkResult where
  docs : Docs
  moduleHistory : ModuleHistories
  applied : Bool := false

def trackedModuleName? (root path : System.FilePath) (backend : Backend) : Option String := do
  guard (backend == .lean)
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
  let relPath? :=
    if pathStr.startsWith rootPrefix then
      some <| (pathStr.drop rootPrefix.length).toString
    else if pathStr == rootStr then
      some "."
    else
      none
  let relPath ← relPath?
  guard (relPath.endsWith ".lean")
  let relFile := System.FilePath.mk relPath
  let stem ← relFile.fileStem
  let parts := relFile.components.dropLast
  some <| String.intercalate "." (parts ++ [stem])

def requireDocState (docs : Docs) (uri : String) : IO DocState := do
  match docs.get? uri with
  | some docState => pure docState
  | none => throw <| IO.userError s!"missing synced document state for {uri}"

def recordFileProgress
    (docs : Docs)
    (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : Docs :=
  match docs.get? uri with
  | some docState =>
      docs.insert uri { docState with fileProgress? := fileProgress? }
  | none =>
      docs

private def nextSnapshotSeq (docState : DocState) (snapshot : FileSnapshot) : Nat :=
  if snapshot.readSeq == 0 then docState.syncSnapshotSeq else snapshot.readSeq

private def docStateOfSnapshot (version : Nat) (snapshot : FileSnapshot) : DocState := {
  version
  textHash := snapshot.textHash
  textTraceHash := snapshot.textTraceHash
  textMTime := snapshot.textMTime
  syncSnapshotSeq := snapshot.readSeq
  moduleName? := snapshot.moduleName?
}

/--
Decide how a freshly read file snapshot should update the broker's LSP document
mirror.

Request handlers reserve nonzero `readSeq` values before reading the filesystem.
If an older read finishes after a newer read has already been applied, the older
snapshot is ignored here. The LSP server only sees the ordered notifications the
broker sends, so this broker-side check prevents stale disk reads from becoming
newer LSP document versions.
-/
def syncFileDecision
    (docs : Docs)
    (uri : DocumentUri)
    (snapshot : FileSnapshot) : SyncFileDecision :=
  match docs.get? uri with
  | none =>
      let version := 1
      {
        action := .open
        version
        docs := docs.insert uri (docStateOfSnapshot version snapshot)
      }
  | some docState =>
      if snapshot.readSeq != 0 && snapshot.readSeq < docState.syncSnapshotSeq then
        {
          action := .unchanged
          version := docState.version
          docs
        }
      else if docState.textHash == snapshot.textHash then
        {
          action := .unchanged
          version := docState.version
          docs := docs.insert uri {
            docState with
            textTraceHash := snapshot.textTraceHash
            textMTime := snapshot.textMTime
            syncSnapshotSeq := nextSnapshotSeq docState snapshot
            moduleName? := snapshot.moduleName?
          }
        }
      else
        let version := docState.version + 1
        {
          action := .change
          version
          docs := docs.insert uri {
            (docStateOfSnapshot version snapshot) with
            savedOleanVersion? := none
            fileProgress? := none
            lastSyncSeq := docState.lastSyncSeq
            lastSaveSeq := docState.lastSaveSeq
            lastSyncSummary? := docState.lastSyncSummary?
          }
        }

def updateModuleHistorySync
    (moduleHistory : ModuleHistories)
    (moduleName path : String)
    (seq : Nat) : ModuleHistories :=
  let history := (moduleHistory.get? moduleName).getD { path }
  moduleHistory.insert moduleName {
    history with
    path
    lastSyncSeq := seq
  }

def updateModuleHistorySave
    (moduleHistory : ModuleHistories)
    (moduleName path : String)
    (seq : Nat) : ModuleHistories :=
  let history := (moduleHistory.get? moduleName).getD { path }
  moduleHistory.insert moduleName {
    history with
    path
    lastSyncSeq := seq
    lastSaveSeq := seq
  }

def moduleHistorySnapshot (moduleHistory : ModuleHistory) : ModuleHistorySnapshot := {
  path := moduleHistory.path
  lastSyncSeq := moduleHistory.lastSyncSeq
  lastSaveSeq := moduleHistory.lastSaveSeq
}

def moduleHistorySnapshots
    (moduleHistory : ModuleHistories) :
    Std.TreeMap String ModuleHistorySnapshot :=
  moduleHistory.foldl (init := {}) fun snapshots moduleName moduleHistory =>
    snapshots.insert moduleName (moduleHistorySnapshot moduleHistory)

def markSyncedVersion
    (docs : Docs)
    (moduleHistory : ModuleHistories)
    (uri : DocumentUri)
    (version : Nat)
    (path : String)
    (seq : Nat) : VersionMarkResult :=
  match docs.get? uri with
  | some docState =>
      if docState.version == version then
        let moduleHistory :=
          match docState.moduleName? with
          | some moduleName => updateModuleHistorySync moduleHistory moduleName path seq
          | none => moduleHistory
        {
          docs := docs.insert uri {
            docState with
            lastSyncSeq := seq
          }
          moduleHistory
          applied := true
        }
      else
        { docs, moduleHistory }
  | none =>
      { docs, moduleHistory }

def recordSyncSummary
    (docs : Docs)
    (uri : DocumentUri)
    (summary : LastSyncSummary) : Docs :=
  match docs.get? uri with
  | some docState =>
      if docState.version == summary.version then
        docs.insert uri { docState with lastSyncSummary? := some summary }
      else
        docs
  | none =>
      docs

def markSavedVersion
    (docs : Docs)
    (moduleHistory : ModuleHistories)
    (uri : DocumentUri)
    (version : Nat)
    (path : String)
    (seq : Nat) : VersionMarkResult :=
  match docs.get? uri with
  | some docState =>
      if docState.version == version then
        let moduleHistory :=
          match docState.moduleName? with
          | some moduleName => updateModuleHistorySave moduleHistory moduleName path seq
          | none => moduleHistory
        {
          docs := docs.insert uri {
            docState with
            savedOleanVersion? := some version
            lastSyncSeq := seq
            lastSaveSeq := seq
          }
          moduleHistory
          applied := true
        }
      else
        { docs, moduleHistory }
  | none =>
      { docs, moduleHistory }

end DocumentState

end Beam.Broker
