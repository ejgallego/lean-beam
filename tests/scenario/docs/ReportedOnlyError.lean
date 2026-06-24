import Lean

open Lean Elab Command

elab "#beam_reported_only_error_snapshot" : command => do
  let ref ← getRef
  let ctx ← read
  let msg : Message := {
    fileName := ctx.fileName
    severity := MessageSeverity.error
    pos := ctx.fileMap.toPosition (ref.getPos?.getD 0)
    data := "reported-only diagnostic from child snapshot"
  }
  let msgLog := (MessageLog.empty.add msg).markAllReported
  let diagnostics ← Lean.Language.Snapshot.Diagnostics.ofMessageLog msgLog
  let tree : Lean.Language.SnapshotTree := .mk { diagnostics } #[]
  logSnapshotTask <| Lean.Language.SnapshotTask.finished none tree

#beam_reported_only_error_snapshot

def reportedOnlyValue : Nat := 1
