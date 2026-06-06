/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Pending
import RunAtTest.Broker.JsonAssert

open Lean
open Lean.JsonRpc
open Beam.Broker
open RunAtTest.Broker.JsonAssert

namespace RunAtTest.Broker.PendingTest

private def expectIoErrorContains (label needle : String) (act : IO α) : IO Unit := do
  let error? ←
    try
      discard <| act
      pure none
    catch e =>
      pure <| some e.toString
  match error? with
  | some error =>
      require label (error.contains needle)
  | none =>
      throw <| IO.userError s!"{label}: expected IO error containing {needle}"

private def mkPending
    (clientRequestId? : Option String := none)
    (progress? : Option SyncFileProgress := none) :
    IO (PendingRequest × IO.Promise (Except String PendingResult)) := do
  let promise ← IO.Promise.new
  let progressRef ← IO.mkRef progress?
  let diagnosticsRef ← IO.mkRef #[]
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  pure ({
    clientRequestId?
    promise
    progressRef
    diagnosticsRef
    seenDiagnosticKeysRef
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
  expectIoErrorContains
    "ensureRequestNotCancelled reports broker cancellation"
    "requestCancelled"
    (ensureRequestNotCancelled (some (ActiveRequest.cancelRef first)))

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
  let result ← PendingRequest.awaitResult promise
  requireJsonBool "pending response result" "value" true result.result
  require "pending response preserves progress"
    (result.progress? == some { updates := 3, done := false })
  require "pending store is empty after remove"
    ((← PendingRequestStore.snapshot store).isEmpty)

private def checkPendingStoreFailAll : IO Unit := do
  let store ← PendingRequestStore.create
  let (pending, promise) ← mkPending
  PendingRequestStore.insert store 11 pending
  PendingRequestStore.failAll store "worker exited"
  expectIoErrorContains
    "failAll resolves pending request as an error"
    "worker exited"
    (discard <| PendingRequest.awaitResult promise)
  require "failAll clears pending store"
    ((← PendingRequestStore.snapshot store).isEmpty)

def main : IO Unit := do
  checkActiveRegistry
  checkPendingStoreResolve
  checkPendingStoreFailAll

end RunAtTest.Broker.PendingTest

def main := RunAtTest.Broker.PendingTest.main
