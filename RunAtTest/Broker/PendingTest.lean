/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Pending
import RunAtTest.Broker.JsonAssert

open Lean
open Lean.JsonRpc
open Lean.Lsp
open Beam.Broker
open RunAtTest.Broker.JsonAssert

namespace RunAtTest.Broker.PendingTest

private def requireErrorCode (label expectedCode : String) (resp : Response) : IO Error := do
  match resp.error? with
  | some err =>
      if err.code != expectedCode then
        throw <| IO.userError s!"{label}: expected code={expectedCode}, got {(toJson resp).compress}"
      pure err
  | none =>
      throw <| IO.userError s!"{label}: expected error response, got {(toJson resp).compress}"

private def mkPending
    (clientRequestId? : Option String := none)
    (progress? : Option SyncFileProgress := none)
    (tracked? : Option (DocumentUri × Nat) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (PendingRequest × IO.Promise (Except Response PendingResult)) := do
  let promise ← IO.Promise.new
  let progressRef ← IO.mkRef progress?
  let diagnosticsRef ← IO.mkRef #[]
  let diagnosticsSeenRef ← IO.mkRef false
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  pure ({
    clientRequestId?
    promise
    tracked?
    progressRef
    diagnosticsRef
    diagnosticsSeenRef
    seenDiagnosticKeysRef
    fullDiagnostics
    emitDiagnostic?
  }, promise)

private def checkActiveRegistry : IO Unit := do
  let registry ← ActiveRequestRegistry.create
  let noneResult ← ActiveRequestRegistry.register registry none
  let noneActive : Option ActiveRequest ←
    expectOk "register without clientRequestId" noneResult
  require "register without clientRequestId returns none" (Option.isNone noneActive)

  let firstResult ← ActiveRequestRegistry.register registry (some "req-1")
  let first? : Option ActiveRequest ←
    expectOk "register active request" firstResult
  let some first := first?
    | throw <| IO.userError "register active request returned none"
  match ← ActiveRequestRegistry.register registry (some "req-1") with
  | .ok _ =>
      throw <| IO.userError "duplicate clientRequestId registered successfully"
  | .error err =>
      require "duplicate active request error names id" (err.contains "req-1")

  require "mark active request cancelled"
    (← ActiveRequestRegistry.markCancelled registry "req-1")
  match ← ensureRequestNotCancelled (some (ActiveRequest.cancelRef first)) with
  | .ok _ =>
      throw <| IO.userError "ensureRequestNotCancelled reports broker cancellation: expected error"
  | .error resp =>
      discard <| requireErrorCode
        "ensureRequestNotCancelled reports broker cancellation"
        "requestCancelled"
        resp

  ActiveRequestRegistry.unregister registry first?
  require "unregistered active request is no longer cancellable"
    (!(← ActiveRequestRegistry.markCancelled registry "req-1"))

private def checkPendingStoreResolve : IO Unit := do
  let store ← PendingRequestStore.create
  let (pending, promise) ← mkPending
    (clientRequestId? := some "req-2")
    (progress? := some { updates := 3, done := false })
  let id : RequestID := 7
  PendingRequestStore.insert store id pending
  let entries ← PendingRequestStore.snapshotEntries store
  require "pending store has inserted request" (entries.size == 1)
  let some pending ← PendingRequestStore.remove store id
    | throw <| IO.userError "pending store remove missed inserted request"
  PendingRequest.resolveResponse pending (Json.mkObj [("value", toJson true)])
  let result ←
    match ← PendingRequest.awaitOutcome promise with
    | .ok result => pure result
    | .error resp =>
        throw <| IO.userError s!"pending response result: expected success, got {(toJson resp).compress}"
  requireJsonBool "pending response result" "value" true result.result
  require "pending response preserves progress"
    (result.progress? == some { updates := 3, done := false })
  require "pending response records no diagnostics publication"
    (!result.diagnosticsSeen)
  require "pending store is empty after remove"
    ((← PendingRequestStore.snapshot store).isEmpty)

private def checkPendingStoreFailAll : IO Unit := do
  let store ← PendingRequestStore.create
  let (pending, promise) ← mkPending
  PendingRequestStore.insert store 11 pending
  PendingRequestStore.failAll store (Response.error "workerExited" "worker exited")
  match ← PendingRequest.awaitOutcome promise with
  | .ok _ =>
      throw <| IO.userError "failAll resolves pending request as an error: expected error"
  | .error resp =>
      discard <| requireErrorCode "failAll resolves pending request as an error" "workerExited" resp
  require "failAll clears pending store"
    ((← PendingRequestStore.snapshot store).isEmpty)

private def mkRange (startLine startCharacter endLine endCharacter : Nat) : Range := {
  start := { line := startLine, character := startCharacter }
  «end» := { line := endLine, character := endCharacter }
}

private def mkFileProgress (ranges : Array Range) : LeanFileProgressParams := {
  textDocument := { uri := "file:///workspace/Foo.lean", version? := some 1 }
  processing := ranges.map fun range => { range }
}

private def mkDiagnostic (range : Range) (message : String) : Diagnostic := {
  range
  fullRange? := some range
  severity? := some .error
  message
}

private def mkDiagnosticWithSeverity
    (range : Range)
    (severity : DiagnosticSeverity)
    (message : String) : Diagnostic := {
  range
  fullRange? := some range
  severity? := some severity
  message
}

private def mkPublishDiagnostics (diagnostics : Array Diagnostic) : PublishDiagnosticsParams := {
  uri := "file:///workspace/Foo.lean"
  version? := some 1
  diagnostics
}

private def observeFileProgress
    (progress : SyncFileProgress)
    (ranges : Array Range) : IO SyncFileProgress := do
  let (pending, _) ← mkPending
    (progress? := some progress)
    (tracked? := some ("file:///workspace/Foo.lean", 1))
  PendingRequest.observeProgress pending (mkFileProgress ranges)
  let some next ← pending.progressRef.get
    | throw <| IO.userError "observeProgress cleared fileProgress"
  pure next

private def checkSyncFileProgressDisplay : IO Unit := do
  require "display includes range and done=false"
    (SyncFileProgress.displayDetails {
      updates := 4
      done := false
      rangeStartLine? := some 3
      rangeEndLine? := some 13
    } == "range=3..13 updates=4 done=false")
  require "display can omit done=true"
    (SyncFileProgress.displayDetails {
      updates := 5
      done := true
      rangeEndLine? := some 13
    } (includeDoneTrue := false) == "rangeEndLine=13 updates=5")

private def checkSyncFileProgressLines : IO Unit := do
  let trailingNewline ← observeFileProgress {} #[mkRange 0 0 1 0]
  require "progress trailing newline reports one-line range bound"
    (trailingNewline == {
      updates := 1
      done := false
      rangeStartLine? := some 1
      rangeEndLine? := some 1
    })

  let multipleRanges ← observeFileProgress {} #[
    mkRange 5 0 10 0,
    mkRange 2 0 12 3
  ]
  require "progress multiple ranges use earliest active line and max range end"
    (multipleRanges == {
      updates := 1
      done := false
      rangeStartLine? := some 3
      rangeEndLine? := some 13
    })

  let finished ← observeFileProgress multipleRanges #[]
  require "progress final empty processing preserves range end and clears active range start"
    (finished == {
      updates := 2
      done := true
      rangeEndLine? := some 13
    })
  let renderedProgress := toJson finished
  requireFieldAbsent "finished progress" "line" renderedProgress
  requireFieldAbsent "finished progress" "totalLines" renderedProgress
  requireJsonInt "finished progress" "rangeEndLine" 13 renderedProgress

private def checkDiagnosticLineCanExceedProgressRange : IO Unit := do
  let active ← observeFileProgress {} #[mkRange 0 0 1 0]
  let finished ← observeFileProgress active #[]
  require "progress fixture ends at one-line range bound"
    (finished == {
      updates := 2
      done := true
      rangeEndLine? := some 1
    })

  let farDiagnostic := mkDiagnostic (mkRange 20 2 20 8) "diagnostic beyond progress range"
  let (pending, _) ← mkPending
    (progress? := some finished)
    (tracked? := some ("file:///workspace/Foo.lean", 1))
  PendingRequest.observeDiagnostics
    (System.FilePath.mk ".")
    pending
    (mkPublishDiagnostics #[farDiagnostic])
  require "diagnostic publication does not rewrite fileProgress range"
    ((← pending.progressRef.get) == some finished)
  let diagnostics ← pending.diagnosticsRef.get
  let some diagnostic := diagnostics[0]?
    | throw <| IO.userError "expected diagnostic beyond progress range"
  require "diagnostic may start beyond progress rangeEndLine"
    (diagnostic.range.start.line + 1 > finished.rangeEndLine?.getD 0)

private def observeStreamedDiagnostics
    (fullDiagnostics : Bool)
    (diagnostics : Array Diagnostic) : IO (Array StreamDiagnostic) := do
  let streamedRef ← IO.mkRef #[]
  let (pending, _) ← mkPending
    (tracked? := some ("file:///workspace/Foo.lean", 1))
    (fullDiagnostics := fullDiagnostics)
    (emitDiagnostic? := some fun diagnostic =>
      streamedRef.modify (·.push diagnostic))
  PendingRequest.observeDiagnostics
    (System.FilePath.mk "/workspace")
    pending
    (mkPublishDiagnostics diagnostics)
  streamedRef.get

private def checkSetupFileProgressStreamsWithoutFullDiagnostics : IO Unit := do
  let setupProgress :=
    mkDiagnosticWithSeverity
      (mkRange 0 0 1 0)
      .information
      "✔ [1/2] Built Liris.Iris.HeapLang.PrimitiveLaws (12s)\n"
  let warning :=
    mkDiagnosticWithSeverity
      (mkRange 3 0 3 6)
      .warning
      "unused variable"
  let defaultStreamed ← observeStreamedDiagnostics false #[setupProgress, warning]
  require "default sync streams setup-file status"
    (defaultStreamed.map (·.message) == #[setupProgress.message])
  require "default setup-file status stays informational"
    (defaultStreamed.all (fun diagnostic => diagnostic.severity? == some .information))

  let fullStreamed ← observeStreamedDiagnostics true #[setupProgress, warning]
  require "full sync streams setup-file status and warning"
    (fullStreamed.map (·.message) == #[setupProgress.message, warning.message])

def main : IO Unit := do
  checkActiveRegistry
  checkPendingStoreResolve
  checkPendingStoreFailAll
  checkSyncFileProgressDisplay
  checkSyncFileProgressLines
  checkDiagnosticLineCanExceedProgressRange
  checkSetupFileProgressStreamsWithoutFullDiagnostics

end RunAtTest.Broker.PendingTest

def main := RunAtTest.Broker.PendingTest.main
