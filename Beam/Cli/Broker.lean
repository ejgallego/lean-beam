/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.DaemonManager
import Beam.Cli.Output
import Beam.Broker.Client
import Beam.Broker.Transport
import Std.Internal.UV.Signal

namespace Beam.Cli

open Beam.Broker

def withBrokerErrorContext {α} (root : System.FilePath) (action : IO α) : IO α := do
  try
    action
  catch e =>
    throw <| IO.userError (← daemonFailureMessage root e.toString)

def callBroker (root : System.FilePath) (endpoint : Transport.Endpoint) (req : Request) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId req
    let resp ← sendRequest endpoint req
    printResponse resp
    failOnError resp

def callBrokerQuiet (root : System.FilePath) (endpoint : Transport.Endpoint) (req : Request) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId req
    let resp ← sendRequest endpoint req
    failOnError resp

structure BrokerWaitSpec where
  action : String
  startMsg : String
  progressMsg : SyncFileProgress → String
  stillWaitingMsg : Nat → String
  completeMsg : Response → String
  failureBoundary : String := "before the request completed"
  responseNote? : Response → Option String := fun _ => none

private structure InterruptWatcher where
  signal : Std.Internal.UV.Signal
  task : Task (Except IO.Error Unit)

def progressEnabled : IO Bool := do
  match ← envFlag? "BEAM_PROGRESS" with
  | some enabled =>
      pure enabled
  | none =>
      (← IO.getStderr).isTty

private def mkInterruptWatcher? (clientRequestId? : Option String) : IO (Option InterruptWatcher) := do
  match clientRequestId? with
  | none => pure none
  | some _ =>
      let signal ← Std.Internal.UV.Signal.mk 2 false
      let task ← IO.asTask do
        let promise ← Std.Internal.UV.Signal.next signal
        let some _ ← IO.wait promise.result?
          | throw <| IO.userError "SIGINT watcher promise dropped"
        pure ()
      pure <| some { signal, task }

def awaitBrokerResponse
    (task : Task (Except IO.Error Response))
    (endpoint : Transport.Endpoint)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Response := do
  let req ← withEnvClientRequestId req
  let interruptWatcher? ← mkInterruptWatcher? req.clientRequestId?
  let mut cancelSent := false
  let emit := fun msg => IO.eprintln <| annotateRunatMessage req.clientRequestId? msg
  emit spec.startMsg
  let mut waitedMs := 0
  try
    while !(← IO.hasFinished task) do
      match interruptWatcher? with
      | some watcher =>
          if !cancelSent && (← IO.hasFinished watcher.task) then
            cancelSent := true
            emit "beam: requesting broker cancellation"
            let cancelReq : Request := {
              op := .cancel
              root? := req.root?
              cancelRequestId? := req.clientRequestId?
            }
            discard <| sendRequest endpoint (← withEnvClientRequestId cancelReq)
      | none =>
          pure ()
      IO.sleep 500
      if !(← IO.hasFinished task) then
        waitedMs := waitedMs + 500
        if waitedMs % 1000 == 0 then
          emit <| spec.stillWaitingMsg (waitedMs / 1000)
    let resp ←
      match (← IO.wait task) with
      | .ok resp => pure resp
      | .error err => throw err
    emit <| spec.completeMsg resp
    pure resp
  finally
    match interruptWatcher? with
    | some watcher => Std.Internal.UV.Signal.stop watcher.signal
    | none => pure ()

private def syncReadinessSuffix (result : SyncFileResult) : String :=
  if result.saveReady then
    ""
  else
    s!", saveReady=false ({result.saveReadyReason}, " ++
    s!"stateErrorCount={result.stateErrorCount}, " ++
      s!"stateCommandErrorCount={result.stateCommandErrorCount})"

private def syncLikeCompleteMsg (completeLabel path : String) (resp : Response) : String :=
  match decodeSyncFileResult? resp with
  | some result =>
      let suffix := syncFileProgressSuffix (responseFileProgress? resp)
      s!"beam: {completeLabel} complete for {path} (version {result.version}{suffix}{syncReadinessSuffix result})"
  | none =>
      s!"beam: {completeLabel} complete for {path}"

private def syncLikeWaitSpec
    (action path startMsg progressLabel stillWaitingLabel completeLabel : String) : BrokerWaitSpec :=
  {
    action
    startMsg
    progressMsg := fun progress => s!"beam: {progressLabel} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still {stillWaitingLabel} {path} ({seconds}s)"
    completeMsg := syncLikeCompleteMsg completeLabel path
    failureBoundary := "before a complete diagnostics barrier was available"
  }

def syncWaitSpec (path : String) : BrokerWaitSpec :=
  syncLikeWaitSpec
    (action := "lean-sync")
    (path := path)
    (startMsg := s!"beam: syncing {path} and waiting for Lean diagnostics")
    (progressLabel := "sync")
    (stillWaitingLabel := "syncing")
    (completeLabel := "sync")

def refreshWaitSpec (path : String) : BrokerWaitSpec :=
  syncLikeWaitSpec
    (action := "lean-refresh")
    (path := path)
    (startMsg := s!"beam: refreshing {path} by closing and resyncing")
    (progressLabel := "refresh")
    (stillWaitingLabel := "refreshing")
    (completeLabel := "refresh")

def leanRunAtWaitSpec (action path : String) (line character : Nat) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: snapshot progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for a ready Lean snapshot for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before probe execution"
    responseNote? := runAtPayloadSummary? action "probe"
  }

def leanHoverWaitSpec (path : String) (line character : Nat) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := "lean-hover"
    startMsg := s!"beam: running lean-hover on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: hover progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for lean-hover on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: lean-hover complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before hover data was available"
  }

def leanGoalsWaitSpec (path : String) (line character : Nat) (mode : GoalMode) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  let action :=
    match mode with
    | .after => "lean-goals-after"
    | .prev => "lean-goals-prev"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: goals progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before goal inspection completed"
  }

def leanTodoWaitSpec
    (path : String)
    (startLine startCharacter endLine endCharacter : Nat) : BrokerWaitSpec :=
  let pos := s!"{path}:{startLine}:{startCharacter}-{endLine}:{endCharacter}"
  {
    action := "lean-todo"
    startMsg := s!"beam: querying lean-todo for {pos} and waiting for Lean diagnostics"
    progressMsg := fun progress => s!"beam: todo progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for lean-todo on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: lean-todo complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before todo inspection completed"
  }

def leanRequestAtWaitSpec (path : String) (line character : Nat) (method : String) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := s!"lean-request-at {method}"
    startMsg := s!"beam: forwarding experimental {method} at {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: request-at progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for experimental {method} at {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: experimental {method} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := s!"before experimental {method} completed"
  }

def leanRunWithWaitSpec (path : String) (linear : Bool := false) : BrokerWaitSpec :=
  let action := if linear then "lean-run-with-linear" else "lean-run-with"
  {
    action := action
    startMsg := s!"beam: running {action} on {path} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before speculative continuation completed"
    responseNote? := runAtPayloadSummary? action "continuation"
  }

def leanSaveWaitSpec (path : String) (closeAfter : Bool := false) : BrokerWaitSpec :=
  let action := if closeAfter then "lean-close-save" else "lean-save"
  let verb := if closeAfter then "closing and saving" else "saving"
  {
    action := action
    startMsg := s!"beam: {verb} {path} and waiting for Lean diagnostics/artifacts"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp => s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before save artifacts were finalized"
  }

def callBrokerWithProgress
    (root : System.FilePath)
    (endpoint : Transport.Endpoint)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Unit :=
  withBrokerErrorContext root do
    let req ← withEnvClientRequestId req
    let showProgress ← progressEnabled
    let callbacks : StreamCallbacks := {
      onFileProgress := fun clientRequestId? progress => do
        if showProgress then
          IO.eprintln <| annotateRunatMessage clientRequestId? (spec.progressMsg progress)
      onDiagnostic := fun clientRequestId? diagnostic =>
        IO.eprintln <| annotateRunatMessage clientRequestId? (formatStreamDiagnostic diagnostic)
    }
    let resp ←
      if showProgress then
        let task ← IO.asTask <| sendRequestWithCallbacks endpoint req callbacks
        awaitBrokerResponse task endpoint req spec
      else
        sendRequestWithCallbacks endpoint req callbacks
    match responseErrorSummary? spec.action spec.failureBoundary resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage req.clientRequestId? note
    | none =>
        pure ()
    match responseRecoveryHint? resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage req.clientRequestId? note
    | none =>
        pure ()
    match spec.responseNote? resp with
    | some note =>
        IO.eprintln <| annotateRunatMessage req.clientRequestId? note
    | none =>
        pure ()
    maybeEmitLiteralBackslashNewlineHint req resp
    printResponse resp
    failOnError resp

end Beam.Cli
