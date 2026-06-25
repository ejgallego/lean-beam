/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Broker.StaleDirectDeps
import Beam.Broker.SyncSaveSupport

open Lean
open Lean.Lsp

namespace Beam.Broker

/--
Pure interpretation of the diagnostics/progress barrier used by `sync`, `save`, and `close-save`.

This deliberately does not mean arbitrary Lean operations are semantically ready. It only names the
specific broker contract for operations that wait for a diagnostics/save barrier.
-/
structure SyncBarrierDecision where
  fileProgress? : Option SyncFileProgress := none
  incomplete : Bool := false
  message? : Option String := none
  deriving Inhabited

def decideSyncBarrier
    (uri : DocumentUri)
    (version : Nat)
    (priorProgress? : Option SyncFileProgress)
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic) : SyncBarrierDecision :=
  let fileProgress? := effectiveSyncBarrierProgress priorProgress? progress? diagnostics
  let incomplete := syncBarrierIncomplete? fileProgress? diagnostics
  {
    fileProgress?
    incomplete
    message? :=
      if incomplete then
        some <| syncBarrierIncompleteMessage uri version fileProgress?
      else
        none
  }

def responseWithFileProgress
    (resp : Response)
    (fileProgress? : Option SyncFileProgress) : Response :=
  match fileProgress? with
  | some progress => { resp with fileProgress? := some progress }
  | none => resp

def syncBarrierIncompleteResponse
    (uri : DocumentUri)
    (version : Nat)
    (targetPath : String)
    (hints : Array StaleDirectDepHint)
    (diagnostics : Array Diagnostic)
    (fileProgress? : Option SyncFileProgress) : Response :=
  Response.error
    syncBarrierIncompleteCode
    (syncBarrierIncompleteMessage uri version fileProgress?)
    (some <| staleSyncErrorData targetPath hints (completionBlockingDiagnostics diagnostics))

def syncFileSuccessPayload
    (syncSummary : SyncSummary)
    (replyDiagnostics? : Option (Array StreamDiagnostic) := none) : Json :=
  toJson <| SyncFileResult.ofSummary syncSummary replyDiagnostics?

def syncFileSuccessResponse
    (syncSummary : SyncSummary)
    (fileProgress? : Option SyncFileProgress)
    (replyDiagnostics? : Option (Array StreamDiagnostic) := none) : Response :=
  responseWithFileProgress
    (Response.success <| syncFileSuccessPayload syncSummary replyDiagnostics?)
    fileProgress?

def savePayloadWithSyncVerdict (payload syncVerdict : Json) : Json :=
  payload.setObjVal! "sync" syncVerdict

def syncVerdictErrorData (syncVerdict : Json) : Json :=
  Json.mkObj [("sync", syncVerdict)]

end Beam.Broker
