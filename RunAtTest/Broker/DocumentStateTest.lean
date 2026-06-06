/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.DocumentState
import RunAtTest.Broker.JsonAssert

open Beam.Broker
open RunAtTest.Broker.JsonAssert

namespace RunAtTest.Broker.DocumentStateTest

private def mkDoc (version : Nat := 1) (moduleName? : Option String := none) : DocState := {
  version
  textHash := 0
  textTraceHash := default
  textMTime := default
  moduleName?
}

private def checkTrackedModuleName : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  require "lean module path"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.lean") .lean == some "Foo.Bar")
  require "non-lean backend has no module"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.lean") .rocq == none)
  require "non-lean file has no module"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.v") .lean == none)
  require "outside root has no module"
    (DocumentState.trackedModuleName? root (System.FilePath.mk "/other/Foo.lean") .lean == none)

private def checkRecordFileProgress : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (mkDoc)
  let docs := DocumentState.recordFileProgress docs uri (some { updates := 2, done := false })
  let some doc := docs.get? uri
    | throw <| IO.userError "recordFileProgress erased existing doc"
  require "recordFileProgress records existing doc progress"
    (doc.fileProgress? == some { updates := 2, done := false })
  let docs := DocumentState.recordFileProgress docs "file:///workspace/Missing.lean" (some {})
  require "recordFileProgress ignores unknown docs" (docs.toList.length == 1)

private def mkSnapshot
    (textHash : UInt64)
    (moduleName? : Option String := some "Foo") : DocumentState.FileSnapshot := {
  textHash
  textTraceHash := default
  textMTime := default
  moduleName?
}

private def checkSyncFileDecisionOpen : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let decision := DocumentState.syncFileDecision {} uri (mkSnapshot 10)
  require "syncFileDecision opens unknown doc" (decision.action == .open)
  require "syncFileDecision open starts at version 1" (decision.version == 1)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision open did not insert doc"
  require "syncFileDecision open records hash" (doc.textHash == 10)
  require "syncFileDecision open records module" (doc.moduleName? == some "Foo")

private def checkSyncFileDecisionUnchanged : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs :=
    Std.TreeMap.empty.insert uri {
      (mkDoc 5 (some "OldFoo")) with
      textHash := 10
      savedOleanVersion? := some 5
      fileProgress? := some { updates := 2, done := true }
      lastSyncSeq := 8
      lastSaveSeq := 7
    }
  let decision := DocumentState.syncFileDecision docs uri (mkSnapshot 10 (some "Foo"))
  require "syncFileDecision unchanged has no LSP action" (decision.action == .unchanged)
  require "syncFileDecision unchanged preserves version" (decision.version == 5)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision unchanged erased doc"
  require "syncFileDecision unchanged preserves saved olean" (doc.savedOleanVersion? == some 5)
  require "syncFileDecision unchanged preserves progress" (doc.fileProgress? == some { updates := 2, done := true })
  require "syncFileDecision unchanged refreshes module" (doc.moduleName? == some "Foo")
  require "syncFileDecision unchanged preserves sync seq" (doc.lastSyncSeq == 8)
  require "syncFileDecision unchanged preserves save seq" (doc.lastSaveSeq == 7)

private def checkSyncFileDecisionChange : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs :=
    Std.TreeMap.empty.insert uri {
      (mkDoc 5 (some "OldFoo")) with
      textHash := 10
      savedOleanVersion? := some 5
      fileProgress? := some { updates := 2, done := true }
      lastSyncSeq := 8
      lastSaveSeq := 7
    }
  let decision := DocumentState.syncFileDecision docs uri (mkSnapshot 11 (some "Foo"))
  require "syncFileDecision changed emits change action" (decision.action == .change)
  require "syncFileDecision changed bumps version" (decision.version == 6)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision changed erased doc"
  require "syncFileDecision changed records hash" (doc.textHash == 11)
  require "syncFileDecision changed records module" (doc.moduleName? == some "Foo")
  require "syncFileDecision changed clears saved olean" (doc.savedOleanVersion?.isNone)
  require "syncFileDecision changed clears progress" (doc.fileProgress?.isNone)
  require "syncFileDecision changed preserves sync seq" (doc.lastSyncSeq == 8)
  require "syncFileDecision changed preserves save seq" (doc.lastSaveSeq == 7)

private def checkMarkSyncedVersion : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (mkDoc 3 (some "Foo"))
  let result := DocumentState.markSyncedVersion docs {} uri 3 "Foo.lean" 7
  require "markSyncedVersion applies matching version" result.applied
  let some doc := result.docs.get? uri
    | throw <| IO.userError "markSyncedVersion erased existing doc"
  require "markSyncedVersion updates document sync seq" (doc.lastSyncSeq == 7)
  let some history := result.moduleHistory.get? "Foo"
    | throw <| IO.userError "markSyncedVersion did not update module history"
  require "markSyncedVersion updates module sync seq" (history.lastSyncSeq == 7)
  require "markSyncedVersion leaves save seq untouched" (history.lastSaveSeq == 0)

  let stale := DocumentState.markSyncedVersion result.docs result.moduleHistory uri 2 "Foo.lean" 8
  require "markSyncedVersion rejects stale version" (!stale.applied)
  let some staleDoc := stale.docs.get? uri
    | throw <| IO.userError "stale markSyncedVersion erased existing doc"
  require "stale markSyncedVersion keeps sync seq" (staleDoc.lastSyncSeq == 7)

private def checkMarkSavedVersion : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (mkDoc 4 (some "Foo"))
  let result := DocumentState.markSavedVersion docs {} uri 4 "Foo.lean" 9
  require "markSavedVersion applies matching version" result.applied
  let some doc := result.docs.get? uri
    | throw <| IO.userError "markSavedVersion erased existing doc"
  require "markSavedVersion records saved version" (doc.savedOleanVersion? == some 4)
  require "markSavedVersion updates document sync seq" (doc.lastSyncSeq == 9)
  require "markSavedVersion updates document save seq" (doc.lastSaveSeq == 9)
  let some history := result.moduleHistory.get? "Foo"
    | throw <| IO.userError "markSavedVersion did not update module history"
  require "markSavedVersion updates module sync seq" (history.lastSyncSeq == 9)
  require "markSavedVersion updates module save seq" (history.lastSaveSeq == 9)

  let stale := DocumentState.markSavedVersion result.docs result.moduleHistory uri 3 "Foo.lean" 10
  require "markSavedVersion rejects stale version" (!stale.applied)
  let some staleDoc := stale.docs.get? uri
    | throw <| IO.userError "stale markSavedVersion erased existing doc"
  require "stale markSavedVersion keeps save seq" (staleDoc.lastSaveSeq == 9)

private def checkModuleHistorySnapshots : IO Unit := do
  let history : DocumentState.ModuleHistories :=
    Std.TreeMap.empty.insert "Foo" {
      path := "Foo.lean"
      lastSyncSeq := 11
      lastSaveSeq := 10
    }
  let snapshots := DocumentState.moduleHistorySnapshots history
  let some snapshot := snapshots.get? "Foo"
    | throw <| IO.userError "moduleHistorySnapshots dropped module"
  require "moduleHistorySnapshots preserves path" (snapshot.path == "Foo.lean")
  require "moduleHistorySnapshots preserves sync seq" (snapshot.lastSyncSeq == 11)
  require "moduleHistorySnapshots preserves save seq" (snapshot.lastSaveSeq == 10)

def main : IO Unit := do
  checkTrackedModuleName
  checkRecordFileProgress
  checkSyncFileDecisionOpen
  checkSyncFileDecisionUnchanged
  checkSyncFileDecisionChange
  checkMarkSyncedVersion
  checkMarkSavedVersion
  checkModuleHistorySnapshots

end RunAtTest.Broker.DocumentStateTest

def main := RunAtTest.Broker.DocumentStateTest.main
