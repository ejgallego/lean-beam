/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Feedback
import Beam.Feedback.Broker
import Beam.Daemon.Debug
import Beam.Lean.Workspace
import Beam.Mcp.Options
import Beam.Mcp.Protocol
import Beam.Mcp.Runtime
import Beam.Mcp.Roots
import Beam.Mcp.SelfCheck
import Beam.Mcp.Stdio
import Beam.System
import Beam.Workspace
import Beam.Version

open Lean

namespace Beam.Mcp.Server

structure ProtocolState where
  initializeComplete : Bool := false
  initializedNotificationSeen : Bool := false
  clientSupportsRoots : Bool := false
  logLevel : LogLevel := .debug
  root? : Option System.FilePath := none
  rootError? : Option String := none
  runtime? : Option Beam.Broker.ServerRuntime := none

def ProtocolState.create (root? : Option System.FilePath := none) : IO (IO.Ref ProtocolState) :=
  IO.mkRef { root? }

structure NotificationSink where
  send : Json → IO Unit := fun _ => pure ()

private structure Notifier where
  state : IO.Ref ProtocolState
  sink : NotificationSink

private def Notifier.send (notifier : Notifier) (json : Json) : IO Unit :=
  notifier.sink.send json

private def ProtocolState.initState (state : ProtocolState) : Beam.Workspace.InitState := {
  root? := state.root?
  runtimeReady := state.runtime?.isSome
}

abbrev Options := Beam.Mcp.Options

private def traceEnabled (envName : String) : IO Bool := do
  match ← IO.getEnv envName with
  | some value => pure (!value.isEmpty && value != "0")
  | none => pure false

private def traceMcp (message : String) : IO Unit := do
  if ← traceEnabled "LEAN_BEAM_MCP_TRACE" then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: {message}"

private def outgoingJsonLabel (json : Json) : String :=
  let idLabel :=
    match json.getObjVal? "id" with
    | .ok id =>
        match RequestId.fromJson? id with
        | .ok id => id.label
        | .error _ => id.compress
    | .error _ => "<none>"
  let methodLabel :=
    match json.getObjVal? "method" with
    | .ok (.str method) => method
    | .ok method => method.compress
    | .error _ => "<none>"
  let kind :=
    if methodLabel != "<none>" then
      "method"
    else if (json.getObjVal? "error").isOk then
      "error"
    else
      "response"
  s!"kind={kind} id={idLabel} method={methodLabel}"

private def writeJsonLine (json : Json) : IO Unit := do
  let payload := json.compress
  let trace := ← traceEnabled "LEAN_BEAM_MCP_TRACE"
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write start {outgoingJsonLabel json} chars={payload.length}"
  let stdout ← IO.getStdout
  stdout.putStr (payload ++ "\n")
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write putStr done {outgoingJsonLabel json}"
  stdout.flush
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write flush done {outgoingJsonLabel json}"

private structure OutputSink where
  mutex : Std.Mutex Unit

private def OutputSink.create : BaseIO OutputSink := do
  pure { mutex := ← Std.Mutex.new () }

private def OutputSink.send (sink : OutputSink) (json : Json) : IO Unit := do
  sink.mutex.atomically do
    writeJsonLine json

private inductive RequestPhase where
  | active
  | clientCancelled
  | completed
  deriving BEq

private structure InFlightState where
  phase : RequestPhase := .active
  runtime? : Option Beam.Broker.ServerRuntime := none
  root? : Option System.FilePath := none

private structure InFlightRequest where
  id : RequestId
  brokerId : String
  state : Std.Mutex InFlightState
  done : IO.Promise Unit

private structure PendingServerRequest where
  promise : IO.Promise (Except String IncomingResponse)

private structure RoutingState where
  nextBrokerId : Nat := 1
  inFlight : Std.TreeMap RequestId InFlightRequest := {}
  pendingServer : Std.TreeMap RequestId PendingServerRequest := {}
  controlBarrier? : Option (IO.Promise Unit) := none
  closing : Bool := false

/-
Nested locks flow toward the routing and output locks:

* setup → routing/output while roots and runtimes are initialized
* progress → request → routing/output while notifications and terminal responses are ordered

Routing and output code must not acquire setup, progress, or request locks.
-/
private structure Coordinator where
  protocol : IO.Ref ProtocolState
  setupMutex : Std.Mutex Unit
  routing : Std.Mutex RoutingState
  output : OutputSink

private def Coordinator.create (root? : Option System.FilePath) : IO Coordinator := do
  pure {
    protocol := ← ProtocolState.create root?
    setupMutex := ← Std.Mutex.new ()
    routing := ← Std.Mutex.new {}
    output := ← OutputSink.create
  }

private def Coordinator.registerRequest
    (coordinator : Coordinator)
    (id : RequestId) : IO (Except RpcError InFlightRequest) := do
  let request : InFlightRequest := {
    id
    brokerId := ""
    state := ← Std.Mutex.new {}
    done := ← IO.Promise.new
  }
  coordinator.routing.atomically do
    let routing ← get
    if routing.closing then
      pure <| .error <| RpcError.invalidRequest "MCP server is shutting down"
    else if routing.inFlight.contains id then
      pure <| .error <| RpcError.invalidRequest s!"request id {id.label} is already active"
    else
      let brokerId := s!"mcp:{routing.nextBrokerId}"
      let request := { request with brokerId }
      set {
        routing with
          nextBrokerId := routing.nextBrokerId + 1
          inFlight := routing.inFlight.insert id request
      }
      pure <| .ok request

private def Coordinator.eraseRequest
    (coordinator : Coordinator)
    (request : InFlightRequest) : IO Unit := do
  coordinator.routing.atomically do
    modify fun routing =>
      match routing.inFlight.get? request.id with
      | some current =>
          if current.brokerId == request.brokerId then
            { routing with inFlight := routing.inFlight.erase request.id }
          else
            routing
      | none => routing

private def InFlightRequest.resolveDone (request : InFlightRequest) : IO Unit := do
  try
    request.done.resolve ()
  catch _ =>
    pure ()

private def InFlightRequest.isActive (request : InFlightRequest) : IO Bool := do
  request.state.atomically do
    pure ((← get).phase == .active)

private def awaitPromise (label : String) (promise : IO.Promise Unit) : IO Unit := do
  let some _ ← IO.wait promise.result?
    | throw <| IO.userError s!"{label} promise was dropped"
  pure ()

private def resolvePromise (promise : IO.Promise Unit) : IO Unit := do
  try
    promise.resolve ()
  catch _ =>
    pure ()

private def Coordinator.currentControlBarrier?
    (coordinator : Coordinator) : IO (Option (IO.Promise Unit)) := do
  coordinator.routing.atomically do
    pure (← get).controlBarrier?

private def Coordinator.pushControlBarrier
    (coordinator : Coordinator) : IO (Option (IO.Promise Unit) × IO.Promise Unit) := do
  let done ← IO.Promise.new
  let previous? ← coordinator.routing.atomically do
    let routing ← get
    set { routing with controlBarrier? := some done }
    pure routing.controlBarrier?
  pure (previous?, done)

private def awaitControlBarrier (barrier? : Option (IO.Promise Unit)) : IO Unit := do
  match barrier? with
  | none => pure ()
  | some barrier => awaitPromise "MCP workspace control" barrier

private def InFlightRequest.sendIfActive
    (request : InFlightRequest)
    (output : OutputSink)
    (json : Json) : IO Unit := do
  request.state.atomically do
    if (← get).phase == .active then
      output.send json

private def InFlightRequest.bindRuntime
    (request : InFlightRequest)
    (runtime : Beam.Broker.ServerRuntime)
    (root : System.FilePath) : IO Bool := do
  request.state.atomically do
    let current ← get
    if current.phase == .active then
      set { current with runtime? := some runtime, root? := some root }
      pure true
    else
      pure false

private def Coordinator.finishRequest
    (coordinator : Coordinator)
    (request : InFlightRequest)
    (response : Json) : IO Unit := do
  try
    request.state.atomically do
      let current ← get
      match current.phase with
      | .active =>
          set { current with phase := .completed }
          coordinator.eraseRequest request
          coordinator.output.send response
      | .clientCancelled =>
          set { current with phase := .completed }
          coordinator.eraseRequest request
      | .completed =>
          pure ()
  finally
    coordinator.eraseRequest request
    request.resolveDone

private def InFlightRequest.markClientCancelled
    (request : InFlightRequest) : IO (Bool × Option (Beam.Broker.ServerRuntime × System.FilePath)) := do
  request.state.atomically do
    let current ← get
    match current.phase with
    | .active =>
        set { current with phase := .clientCancelled }
        pure (true, current.runtime?.bind fun runtime => current.root?.map fun root => (runtime, root))
    | .clientCancelled | .completed =>
        pure (false, none)

private def cancelRegistrationRetryMs : Nat :=
  10

private partial def cancelBrokerUntilTerminal
    (request : InFlightRequest)
    (runtime : Beam.Broker.ServerRuntime)
    (root : System.FilePath) : IO Unit := do
  let phase ← request.state.atomically do
    pure (← get).phase
  if phase == .completed then
    return
  let (response, _) ← runtime.dispatchRequest {
    op := .cancel
    root? := some root.toString
    cancelRequestId? := some request.brokerId
  }
  let acknowledged :=
    response.result?.bind fun result =>
      (result.getObjValAs? Bool "cancelled").toOption
  if acknowledged != some true then
    -- Binding the runtime precedes registration in the broker's active-request table. Retry across
    -- that small window; the request phase terminates the loop if dispatch finishes first.
    IO.sleep cancelRegistrationRetryMs.toUInt32
    cancelBrokerUntilTerminal request runtime root

private def Coordinator.cancelRequest
    (coordinator : Coordinator)
    (id : RequestId) : IO Unit := do
  let request? ← coordinator.routing.atomically do
    pure <| (← get).inFlight.get? id
  match request? with
  | none => pure ()
  | some request =>
      let (cancelled, runtime?) ← request.markClientCancelled
      if cancelled then
        match runtime? with
        | none => pure ()
        | some (runtime, root) =>
            let _ ← IO.asTask (prio := Task.Priority.dedicated) do
              try
                cancelBrokerUntilTerminal request runtime root
              catch e =>
                traceMcp s!"broker cancellation failed id={id.label}: {e.toString}"
            pure ()

private def Coordinator.beginClosing
    (coordinator : Coordinator)
    (reason : String) : IO (Bool × Array InFlightRequest) := do
  let (alreadyClosing, requests, pending) ← coordinator.routing.atomically do
    let routing ← get
    let requests := routing.inFlight.toList.map Prod.snd |>.toArray
    let pending := routing.pendingServer.toList.map Prod.snd |>.toArray
    set {
      routing with
        closing := true
        pendingServer := {}
    }
    pure (routing.closing, requests, pending)
  for pendingRequest in pending do
    try
      pendingRequest.promise.resolve (.error reason)
    catch _ =>
      pure ()
  for request in requests do
    coordinator.cancelRequest request.id
  pure (alreadyClosing, requests)

private def awaitRequestDone (request : InFlightRequest) : IO Unit := do
  awaitPromise s!"in-flight request {request.id.label}" request.done

private def Coordinator.awaitRequests
    (_coordinator : Coordinator)
    (requests : Array InFlightRequest) : IO Unit := do
  for request in requests do
    awaitRequestDone request

private def Coordinator.closeTransport (coordinator : Coordinator) : IO Unit := do
  let (alreadyClosing, requests) ←
    coordinator.beginClosing "MCP client transport closed"
  coordinator.awaitRequests requests
  unless alreadyClosing do
    coordinator.setupMutex.atomically do
      let currentState ← coordinator.protocol.get
      match currentState.runtime? with
      | none => pure ()
      | some runtime =>
          discard <| runtime.dispatchRequest { op := .shutdown }

private def Coordinator.routeResponse
    (coordinator : Coordinator)
    (response : IncomingResponse) : IO Unit := do
  let pending? ← coordinator.routing.atomically do
    let routing ← get
    let pending? := routing.pendingServer.get? response.id
    set { routing with pendingServer := routing.pendingServer.erase response.id }
    pure pending?
  match pending? with
  | none =>
      traceMcp s!"ignoring response for unknown server request id={response.id.label}"
  | some pending =>
      try
        pending.promise.resolve (.ok response)
      catch _ =>
        pure ()

private def Coordinator.requestClientRoot (coordinator : Coordinator) : IO (Except String System.FilePath) := do
  let id : RequestId := .string rootsListRequestId
  let promise ← IO.Promise.new
  let inserted ← coordinator.routing.atomically do
    let routing ← get
    if routing.pendingServer.contains id then
      pure false
    else
      set {
        routing with
          pendingServer := routing.pendingServer.insert id { promise }
      }
      pure true
  if !inserted then
    return .error "roots/list request is already pending"
  try
    coordinator.output.send rootsListRequest
    let some response ← IO.wait promise.result?
      | return .error "roots/list response promise was dropped"
    match response with
    | .error err => pure <| .error err
    | .ok response => Roots.selectClientRootResponse response
  catch e =>
    coordinator.routing.atomically do
      modify fun routing => {
        routing with pendingServer := routing.pendingServer.erase id
      }
    pure <| .error e.toString

private structure ProgressState where
  nextProgress : Nat := 0
  lastFileProgress : Option Beam.Broker.SyncFileProgress := none

private structure ProgressEmitter where
  progressToken : Json
  state : Std.Mutex ProgressState
  emitNotification : Json → IO Unit

private def fileProgressUpdateStride : Nat :=
  25

private def fileProgressMessage (tool : ToolName) (progress : Beam.Broker.SyncFileProgress) : String :=
  s!"{tool.key} fileProgress {Beam.Broker.SyncFileProgress.displayDetails progress}"

private def shouldEmitFileProgress
    (last? : Option Beam.Broker.SyncFileProgress)
    (progress : Beam.Broker.SyncFileProgress) : Bool :=
  match last? with
  | none => true
  | some last =>
      (progress.done && progress != last) ||
        progress.updates >= last.updates + fileProgressUpdateStride

private def ProgressEmitter.create?
    (progressToken? : Option Json)
    (emitNotification : Json → IO Unit) : IO (Option ProgressEmitter) := do
  match progressToken? with
  | none => pure none
  | some progressToken =>
      pure <| some {
        progressToken
        state := ← Std.Mutex.new {}
        emitNotification
      }

private def ProgressEmitter.emit
    (emitter : ProgressEmitter)
    (message : String)
    (total? : Option Nat := none) : IO Unit := do
  emitter.state.atomically do
    let current ← get
    let next := current.nextProgress + 1
    set { current with nextProgress := next }
    emitter.emitNotification <| progressNotification emitter.progressToken next (some message) total?

private def ProgressEmitter.emitFileProgress
    (emitter : ProgressEmitter)
    (tool : ToolName)
    (fileProgress : Beam.Broker.SyncFileProgress) : IO Unit := do
  emitter.state.atomically do
    let current ← get
    if shouldEmitFileProgress current.lastFileProgress fileProgress then
      let next := current.nextProgress + 1
      set { current with
        nextProgress := next
        lastFileProgress := some fileProgress
      }
      emitter.emitNotification <|
        progressNotification emitter.progressToken next (some <| fileProgressMessage tool fileProgress)

private def emitProgress?
    (progress? : Option ProgressEmitter)
    (message : String)
    (total? : Option Nat := none) : IO Unit := do
  match progress? with
  | some progress => progress.emit message total?
  | none => pure ()

private def invalidRequestId (json : Json) : Json :=
  match json.getObjVal? "id" with
  | .ok id =>
      if (RequestId.fromJson? id).isOk then id else Json.null
  | .error _ => Json.null

private def diagnosticSeverityName : Option Lean.Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "information"
  | some .hint => "hint"
  | none => "unknown"

private def diagnosticLogLevel : Option Lean.Lsp.DiagnosticSeverity → LogLevel
  | some .error => .error
  | some .warning => .warning
  | some .information => .info
  | some .hint => .debug
  | none => .info

private def streamDiagnosticLogData (diagnostic : Beam.Broker.StreamDiagnostic) : Json :=
  Json.mkObj <|
    [
      ("path", toJson diagnostic.path),
      ("uri", toJson diagnostic.uri),
      ("severity", toJson <| diagnosticSeverityName diagnostic.severity?),
      ("range", toJson diagnostic.range),
      ("message", toJson diagnostic.message),
      ("completionBlocking", toJson diagnostic.completionBlocking)
    ] ++
    (match diagnostic.saveBlocking? with
    | some saveBlocking => [("saveBlocking", toJson saveBlocking)]
    | none => []) ++
    match diagnostic.version? with
    | some version => [("version", toJson version)]
    | none => []

private def emitDiagnosticLog
    (notifier : Notifier)
    (diagnostic : Beam.Broker.StreamDiagnostic) : IO Unit := do
  let level := diagnosticLogLevel diagnostic.severity?
  let currentState ← notifier.state.get
  if currentState.logLevel.allows level then
    notifier.send <|
      logMessageNotification level "lean.diagnostic" (streamDiagnosticLogData diagnostic)

private def runtimeOptions (opts : Options) : Runtime.Options := {
  leanCmd? := opts.leanCmd?
  leanPlugin? := opts.leanPlugin?
  beamCli? := opts.beamCli?
}

private def createRuntimeForRoot
    (opts : Options)
    (root : System.FilePath) :
    IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  match ← Runtime.mkBrokerConfig (runtimeOptions opts) root with
  | .error err =>
      pure <| .error err
  | .ok config =>
      try
        let runtime ← Beam.Broker.ServerRuntime.create config
        pure <| .ok (runtime, config.root)
      catch e =>
        pure <| .error <| runtimeSetupError e.toString

private def ensureRoot
    (state : IO.Ref ProtocolState)
    (requestRoot : IO (Except String System.FilePath)) : IO (Except RpcError System.FilePath) := do
  let currentState ← state.get
  match currentState.rootError? with
  | some err =>
      pure <| .error <| RpcError.invalidRequest err
  | none =>
      match currentState.root? with
      | some root => pure <| .ok root
      | none =>
          let root? ←
            if currentState.clientSupportsRoots then
              requestRoot
            else
              pure <| .error Roots.unsupportedMessage
          match root? with
          | .error err =>
              state.modify fun state => { state with rootError? := some err }
              pure <| .error <| RpcError.invalidRequest err
          | .ok root =>
              state.modify fun state => { state with root? := some root }
              pure <| .ok root

private def ensureRuntime
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (requestRoot : IO (Except String System.FilePath)) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  setupMutex.atomically do
    let currentState ← state.get
    match currentState.runtime?, currentState.root? with
    | some runtime, some root =>
        pure <| .ok (runtime, root)
    | _, _ =>
        match ← ensureRoot state requestRoot with
        | .error err => pure <| .error err
        | .ok root =>
            match ← createRuntimeForRoot opts root with
            | .error err =>
                state.modify fun state => { state with rootError? := some err.message }
                pure <| .error err
            | .ok (runtime, root) =>
                state.modify fun state => { state with root? := some root, runtime? := some runtime }
                pure <| .ok (runtime, root)

private def workspaceErrorToToolError (err : Beam.Workspace.InitError) : ToolError :=
  let data? := err.activeRoot?.map fun activeRoot =>
    Json.mkObj [("active_root", toJson activeRoot.toString)]
  { ToolError.invalidInput err.message with data? }

private def shutdownRuntimeForReset (runtime : Beam.Broker.ServerRuntime) : IO (Except ToolError Unit) := do
  let (brokerResp, _) ← runtime.dispatchRequest { op := .shutdown }
  if brokerResp.ok then
    pure <| .ok ()
  else
    let message := (brokerResp.error?.map (·.message)).getD "Beam broker shutdown failed"
    pure <| .error <| ToolError.runtimeSetup s!"failed to reset MCP workspace: {message}"

private def resetRuntimeHandoff
    (oldRuntime? : Option Beam.Broker.ServerRuntime)
    (newRuntime : Beam.Broker.ServerRuntime) : IO (Except ToolError Unit) := do
  match oldRuntime? with
  | none => pure <| .ok ()
  | some oldRuntime =>
      match ← shutdownRuntimeForReset oldRuntime with
      | .ok () => pure <| .ok ()
      | .error err =>
          discard <| shutdownRuntimeForReset newRuntime
          pure <| .error err

private def handleInitWorkspace
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := setupMutex.atomically do
  let input ←
    match fromJson? (α := InitWorkspaceInput) arguments with
    | .ok input => pure input
    | .error err =>
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let requestedRoot ←
    match ← Beam.Lean.Workspace.resolveRoot input.root with
    | .ok root => pure root
    | .error err =>
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| workspaceErrorToToolError err
  let mode := input.mode
  let currentState ← state.get
  let plan ←
    match Beam.Workspace.planInit currentState.initState requestedRoot mode with
    | .ok plan => pure plan
    | .error err =>
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| workspaceErrorToToolError err
  if !plan.createRuntime then
    emitProgress? progress? "workspace runtime already active"
    emitProgress? progress? "completed lean_init_workspace"
    return callToolResult <| withCapabilities <| toJson <| Beam.Workspace.initResult plan
  emitProgress? progress? "starting workspace runtime"
  match ← createRuntimeForRoot opts requestedRoot with
  | .error err =>
      emitProgress? progress? "lean_init_workspace failed"
      return callToolErrorResult <| ToolError.runtimeSetup err.message
  | .ok (runtime, root) =>
      if plan.resetCurrent then
        emitProgress? progress? "resetting previous workspace runtime"
        match ← resetRuntimeHandoff currentState.runtime? runtime with
        | .ok () => pure ()
        | .error err =>
            emitProgress? progress? "lean_init_workspace failed"
            return callToolErrorResult err
      state.set {
        currentState with
          root? := some root
          rootError? := none
          runtime? := some runtime
      }
      emitProgress? progress? "completed lean_init_workspace"
      pure <| callToolResult <| withCapabilities <| toJson <| Beam.Workspace.initResult plan root

private def resolvedBeamHome? : IO (Option System.FilePath) := do
  match ← IO.getEnv "BEAM_HOME" with
  | some home =>
      try
        pure <| some (← IO.FS.realPath <| System.FilePath.mk home)
      catch _ =>
        pure <| some (System.FilePath.mk home)
  | none => pure none

private def serverIdentity
    (opts : Options)
    (activeRoot? : Option System.FilePath := none)
    (runtimeActive? : Option Bool := none) : IO Beam.Version.Identity := do
  let home? ← resolvedBeamHome?
  let appPath ← IO.appPath
  let wrapper? ← IO.getEnv "BEAM_WRAPPER_PATH"
  Beam.Version.mcpServerIdentity
    home?
    opts.beamCli?
    (some appPath.toString)
    activeRoot?
    runtimeActive?
    (wrapper? := wrapper?)

private def serverVersionText (opts : Options) : IO String := do
  pure (← serverIdentity opts).text

private def handleBeamVersion
    (state : IO.Ref ProtocolState)
    (opts : Options) : IO Json := do
  let currentState ← state.get
  let identity ← serverIdentity opts currentState.root? (some currentState.runtime?.isSome)
  pure <| callToolResult identity.asJson

private def collectFeedbackRuntimePayload
    (runtime? : Option Beam.Broker.ServerRuntime)
    (root? : Option System.FilePath)
    (warnings : Array String) : IO (Json × Json × Array String) := do
  match runtime? with
  | none =>
      pure (Json.null, Json.null, warnings.push "no active MCP Lean runtime was available for stats/open-files")
  | some runtime =>
      let (statsResp, _) ← runtime.dispatchRequest { op := .stats }
      let (stats, warnings) := Beam.Feedback.responsePayloadOrWarning "stats" statsResp warnings
      let (openResp, _) ← runtime.dispatchRequest { op := .openDocs, root? := root?.map (·.toString) }
      let (openDocs, warnings) := Beam.Feedback.responsePayloadOrWarning "open-files" openResp warnings
      pure (stats, openDocs, warnings)

private def feedbackAllowedRoots
    (root? : Option System.FilePath) : IO (Array System.FilePath) := do
  match root? with
  | some root => do
      let control ← Beam.Daemon.controlDir root
      pure #[root, control]
  | none => pure #[]

private def feedbackIncludeCollected (arguments : Json) : Except String Bool := do
  match arguments.getObjVal? "include_collected" with
  | .ok value =>
      match fromJson? (α := Bool) value with
      | .ok includeCollected => pure includeCollected
      | .error err => throw s!"invalid 'include_collected': {err}"
  | .error _ => pure false

private def handleBeamFeedback
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  let input ←
    match fromJson? (α := Beam.Feedback.Input) arguments with
    | .ok input => pure input
    | .error err =>
        emitProgress? progress? "beam_feedback failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let includeCollected ←
    match feedbackIncludeCollected arguments with
    | .ok includeCollected => pure includeCollected
    | .error err =>
        emitProgress? progress? "beam_feedback failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let currentState ← state.get
  emitProgress? progress? "collecting beam_feedback context"
  let generatedAt ← Beam.utcTimestamp
  let identity ← serverIdentity opts currentState.root? (some currentState.runtime?.isSome)
  let mut warnings := #[]
  let daemon ←
    match currentState.root? with
    | some root => Beam.Daemon.daemonDebugContextJson root
    | none =>
        warnings := warnings.push "no active MCP root was available for daemon registry context"
        pure Json.null
  let warningsWithDaemon := warnings ++ Beam.Daemon.daemonDebugWarnings daemon
  let (stats, openDocs, warnings') ←
    collectFeedbackRuntimePayload currentState.runtime? currentState.root? warningsWithDaemon
  let collection : Beam.Feedback.Collection := {
    generatedAt
    activeRoot? := currentState.root?.map (·.toString)
    data := Json.mkObj [
      ("identity", identity.asJson),
      ("stats", stats),
      ("openFiles", openDocs),
      ("daemon", daemon)
    ]
    warnings := warnings'
  }
  let allowedRoots ← feedbackAllowedRoots currentState.root?
  try
    let result ← Beam.Feedback.buildResult input collection {
      root? := currentState.root?
      allowedRoots
    }
    let markdown ← Beam.Feedback.renderMcpMarkdown input collection includeCollected
    emitProgress? progress? "completed beam_feedback"
    pure <| callToolResult <| Beam.Feedback.resultMcpJson result markdown includeCollected
  catch e =>
    emitProgress? progress? "beam_feedback failed"
    pure <| callToolErrorResult <| ToolError.invalidInput e.toString

private def brokerRequestForTool
    (root : System.FilePath)
    (params : CallToolParams)
    (clientRequestId : String) : Except String Beam.Broker.Request := do
  let req ← params.name.toBrokerRequest root.toString params.arguments
  pure { req with clientRequestId? := some clientRequestId }

private def handleToolCall
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (requestRoot : IO (Except String System.FilePath))
    (brokerClientRequestId : String)
    (beforeDispatch : Beam.Broker.ServerRuntime → System.FilePath → IO Bool)
    (req : Request)
    (notifications : NotificationSink) : IO (Except RpcError Json) := do
  let notifier : Notifier := { state, sink := notifications }
  let params ←
    match parseCallToolParams req.params? with
    | .ok params => pure params
    | .error err => return .error <| RpcError.invalidParams err
  let progress? ← ProgressEmitter.create? params.progressToken? notifier.send
  traceMcp
    s!"tools/call start id={req.id.label} tool={params.name.key} progressToken={params.progressToken?.isSome}"
  if params.name == .leanInitWorkspace then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleInitWorkspace state opts setupMutex params.arguments progress?
    traceMcp s!"tools/call init complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .beamVersion then
    let result ← handleBeamVersion state opts
    traceMcp s!"tools/call version complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .beamFeedback then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleBeamFeedback state opts params.arguments progress?
    traceMcp s!"tools/call feedback complete id={req.id.label} tool={params.name.key}"
    return .ok result
  let root ←
    match ← setupMutex.atomically do ensureRoot state requestRoot with
    | .ok root =>
        traceMcp s!"tools/call root ready id={req.id.label} root={root}"
        pure root
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        traceMcp s!"tools/call root failed id={req.id.label} tool={params.name.key}"
        return .error err
  emitProgress? progress? s!"starting {params.name.key}"
  emitProgress? progress? s!"preparing {params.name.key}"
  let brokerReq ←
    match brokerRequestForTool root params brokerClientRequestId with
    | .ok brokerReq => pure brokerReq
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        traceMcp s!"tools/call invalid input id={req.id.label} tool={params.name.key} error={err}"
        return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let (runtime, _) ←
    match ← ensureRuntime state opts setupMutex requestRoot with
    | .ok runtimeAndRoot =>
        traceMcp s!"tools/call runtime ready id={req.id.label} tool={params.name.key}"
        pure runtimeAndRoot
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        traceMcp s!"tools/call runtime failed id={req.id.label} tool={params.name.key}"
        return .error err
  unless ← beforeDispatch runtime root do
    return .error <| RpcError.invalidRequest "request was cancelled before broker dispatch"
  let emitDiagnostic : Beam.Broker.StreamDiagnostic → IO Unit := fun diagnostic =>
    emitDiagnosticLog notifier diagnostic
  let emitBrokerProgress? : Option (Beam.Broker.SyncFileProgress → IO Unit) :=
    progress?.map fun progress => fun fileProgress =>
      progress.emitFileProgress params.name fileProgress
  emitProgress? progress? s!"running {params.name.key}"
  traceMcp s!"tools/call dispatch broker id={req.id.label} tool={params.name.key}"
  let (brokerResp, _) ← runtime.dispatchRequest brokerReq
    (emitProgress? := emitBrokerProgress?)
    (emitDiagnostic? := some emitDiagnostic)
  traceMcp
    s!"tools/call broker returned id={req.id.label} tool={params.name.key} ok={brokerResp.ok}"
  match normalizeBrokerResponse params.name brokerResp with
  | .ok result =>
      traceMcp s!"tools/call response ready id={req.id.label} tool={params.name.key}"
      pure <| .ok <| callToolResult <| Beam.Workspace.addActiveRoot root result
  | .error err =>
      traceMcp s!"tools/call tool error id={req.id.label} tool={params.name.key}"
      pure <| .ok <| callToolErrorResult err

private def handleReadyOperationRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (requestRoot : IO (Except String System.FilePath))
    (brokerClientRequestId : String)
    (req : Request)
    (notifications : NotificationSink) : IO (Json × Bool) := do
  match req.method with
  | "tools/list" =>
      pure (successResponse req.id toolsListResult, false)
  | "tools/call" =>
      match ← handleToolCall state opts setupMutex requestRoot brokerClientRequestId
          (fun _ _ => pure true) req notifications with
      | .ok result => pure (successResponse req.id result, false)
      | .error err => pure (errorResponse req.id err, false)
  | method =>
      pure (errorResponse req.id (RpcError.methodNotFound method), false)

private def handleSetLogLevel
    (state : IO.Ref ProtocolState)
    (req : Request) : IO (Json × Bool) := do
  match parseSetLogLevelParams req.params? with
  | .ok level =>
      state.modify fun currentState => { currentState with logLevel := level }
      pure (successResponse req.id (Json.mkObj []), false)
  | .error err =>
      pure (errorResponse req.id (RpcError.invalidParams err), false)

def handleRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (req : Request)
    (notifications : NotificationSink := {}) : IO (Json × Bool) := do
  let setupMutex ← Std.Mutex.new ()
  let requestRoot : IO (Except String System.FilePath) :=
    pure <| .error Roots.unsupportedMessage
  let brokerClientRequestId := s!"mcp:sync:{req.id.label}"
  let currentState ← state.get
  match req.method with
  | "initialize" =>
      if currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize has already completed"), false)
      else
        state.set {
          currentState with
            initializeComplete := true
            clientSupportsRoots := clientSupportsRoots req.params?
        }
        pure (successResponse req.id initializeResult, false)
  | "ping" =>
      pure (successResponse req.id (Json.mkObj []), false)
  | "logging/setLevel" =>
      if !currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize must complete before MCP logging requests"), false)
      else
        handleSetLogLevel state req
  | "shutdown" =>
      match currentState.runtime? with
      | none =>
          pure (successResponse req.id (Json.mkObj []), true)
      | some runtime =>
          let (brokerResp, _) ← runtime.dispatchRequest { op := .shutdown }
          if brokerResp.ok then
            pure (successResponse req.id (Json.mkObj []), true)
          else
            let message := (brokerResp.error?.map (·.message)).getD "Beam broker shutdown failed"
            pure (errorResponse req.id (RpcError.internalError message), false)
  | "tools/list" | "tools/call" =>
      if !currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize must complete before MCP operation requests"), false)
      else if !currentState.initializedNotificationSeen then
        pure (errorResponse req.id (RpcError.invalidRequest "notifications/initialized is required before MCP operation requests"), false)
      else
        handleReadyOperationRequest
          state opts setupMutex requestRoot brokerClientRequestId req notifications
  | method =>
      if !currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize must be the first MCP operation"), false)
      else
        pure (errorResponse req.id (RpcError.methodNotFound method), false)

def handleNotification
    (state : IO.Ref ProtocolState)
    (notification : Notification) : IO Bool := do
  match notification.method with
  | "notifications/initialized" =>
      let currentState ← state.get
      if currentState.initializeComplete then
        state.set { currentState with initializedNotificationSeen := true }
      pure false
  | "exit" => pure true
  | _ => pure false

def handleJson
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (json : Json)
    (notifications : NotificationSink := {}) : IO (Option Json × Bool) := do
  match Incoming.fromJson? json with
  | .ok (.request req) =>
      let (resp, stop) ← handleRequest state opts req notifications
      pure (some resp, stop)
  | .ok (.notification notification) =>
      let stop ← handleNotification state notification
      pure (none, stop)
  | .ok (.response _) =>
      pure (none, false)
  | .error err =>
      pure (some <| errorResponse (invalidRequestId json) (RpcError.invalidRequest err), false)

private def Coordinator.admitToolRequest
    (coordinator : Coordinator)
    (req : Request) : IO (Except Json InFlightRequest) := do
  let currentState ← coordinator.protocol.get
  if !currentState.initializeComplete then
    return .error <| errorResponse req.id <|
        RpcError.invalidRequest "initialize must complete before MCP operation requests"
  if !currentState.initializedNotificationSeen then
    return .error <| errorResponse req.id <|
        RpcError.invalidRequest "notifications/initialized is required before MCP operation requests"
  match ← coordinator.registerRequest req.id with
  | .ok request => pure <| .ok request
  | .error err => pure <| .error <| errorResponse req.id err

private def Coordinator.executeToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request)
    (request : InFlightRequest) : IO Json := do
  let notifications : NotificationSink := {
    send := fun json => request.sendIfActive coordinator.output json
  }
  try
    match ← handleToolCall
        coordinator.protocol
        opts
        coordinator.setupMutex
        coordinator.requestClientRoot
        request.brokerId
        request.bindRuntime
        req
        notifications with
    | .ok result => pure <| successResponse req.id result
    | .error err => pure <| errorResponse req.id err
  catch e =>
    pure <| errorResponse req.id (RpcError.internalError e.toString)

private def Coordinator.runToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request)
    (request : InFlightRequest)
    (barrier? : Option (IO.Promise Unit)) : IO Unit := do
  let response ←
    try
      awaitControlBarrier barrier?
      if ← request.isActive then
        coordinator.executeToolRequest opts req request
      else
        pure <| errorResponse req.id <|
          RpcError.invalidRequest "request was cancelled before execution"
    catch e =>
      pure <| errorResponse req.id (RpcError.internalError e.toString)
  coordinator.finishRequest request response

private def Coordinator.spawnToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request) : IO Unit := do
  let request ←
    match ← coordinator.admitToolRequest req with
    | .ok request => pure request
    | .error response =>
        coordinator.output.send response
        return
  let barrier? ← coordinator.currentControlBarrier?
  let _ ← IO.asTask (prio := Task.Priority.dedicated) do
    try
      coordinator.runToolRequest opts req request barrier?
    catch e =>
      if !Beam.Mcp.Stdio.isBrokenPipeError e then
        traceMcp s!"request completion failed id={req.id.label}: {e.toString}"
  pure ()

private def Coordinator.handleControlToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request) : IO Unit := do
  match ← coordinator.admitToolRequest req with
  | .error response => coordinator.output.send response
  | .ok request =>
      let (previous?, done) ← coordinator.pushControlBarrier
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        try
          coordinator.runToolRequest opts req request previous?
        catch e =>
          if !Beam.Mcp.Stdio.isBrokenPipeError e then
            traceMcp s!"workspace control completion failed id={req.id.label}: {e.toString}"
        finally
          resolvePromise done
      pure ()

private def isWorkspaceInit (req : Request) : Bool :=
  if req.method != "tools/call" then
    false
  else
    match parseCallToolParams req.params? with
    | .ok params => params.name == .leanInitWorkspace
    | .error _ => false

private def Coordinator.handleNotification
    (coordinator : Coordinator)
    (notification : Notification) : IO Bool := do
  match notification.method with
  | "notifications/cancelled" =>
      match parseCancelledParams notification.params? with
      | .ok params => coordinator.cancelRequest params.requestId
      | .error err => traceMcp s!"ignoring invalid notifications/cancelled: {err}"
      pure false
  | _ =>
      Beam.Mcp.Server.handleNotification coordinator.protocol notification

private def Coordinator.handleShutdown
    (coordinator : Coordinator)
    (req : Request) : IO Unit := do
  let (_, requests) ← coordinator.beginClosing "MCP server is shutting down"
  coordinator.awaitRequests requests
  let response ← coordinator.setupMutex.atomically do
    let currentState ← coordinator.protocol.get
    match currentState.runtime? with
    | none =>
        pure <| successResponse req.id (Json.mkObj [])
    | some runtime =>
        let (brokerResp, _) ← runtime.dispatchRequest { op := .shutdown }
        if brokerResp.ok then
          pure <| successResponse req.id (Json.mkObj [])
        else
          let message := (brokerResp.error?.map (·.message)).getD "Beam broker shutdown failed"
          pure <| errorResponse req.id (RpcError.internalError message)
  coordinator.output.send response

private def Coordinator.handleIncoming
    (coordinator : Coordinator)
    (opts : Options)
    (incoming : Incoming) : IO Bool := do
  match incoming with
  | .request req =>
      if req.method == "shutdown" then
        coordinator.handleShutdown req
        pure true
      else if isWorkspaceInit req then
        coordinator.handleControlToolRequest opts req
        pure false
      else if req.method == "tools/call" then
        coordinator.spawnToolRequest opts req
        pure false
      else
        let (response, stop) ← handleRequest coordinator.protocol opts req {
          send := coordinator.output.send
        }
        coordinator.output.send response
        pure stop
  | .notification notification =>
      coordinator.handleNotification notification
  | .response response =>
      coordinator.routeResponse response
      pure false

partial def runStdio (opts : Options) (root? : Option System.FilePath) : IO Unit := do
  let stdin ← IO.getStdin
  let coordinator ← Coordinator.create root?
  let rec loop : IO Unit := do
    let line := Beam.Mcp.Stdio.stripLineEnding (← stdin.getLine)
    if line.isEmpty then
      pure ()
    else
      match Json.parse line with
      | .error err =>
          coordinator.output.send <| errorResponse Json.null (RpcError.parseError err)
          loop
      | .ok json =>
          let stop ←
            match Incoming.fromJson? json with
            | .ok incoming => coordinator.handleIncoming opts incoming
            | .error err =>
                coordinator.output.send <|
                  errorResponse (invalidRequestId json) (RpcError.invalidRequest err)
                pure false
          unless stop do
            loop
  try
    loop
  catch e =>
    if Beam.Mcp.Stdio.isBrokenPipeError e then
      pure ()
    else
      throw e
  finally
    coordinator.closeTransport

private def requireStartupRoot (rootText : String) : IO System.FilePath := do
  match ← Beam.Lean.Workspace.resolveCliRoot rootText with
  | .ok root => pure root
  | .error err => throw <| IO.userError err.message

def main (args : List String) : IO Unit := do
  let opts ←
    match Beam.Mcp.parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  if opts.showVersion then
    IO.println (← serverVersionText opts)
    return
  match opts.selfCheckPath? with
  | some path =>
      SelfCheck.run {
        root? := opts.root?
        leanCmd? := opts.leanCmd?
        leanPlugin? := opts.leanPlugin?
        beamCli? := opts.beamCli?
      } path
  | none =>
      let root? ← opts.root?.mapM requireStartupRoot
      runStdio opts root?

end Beam.Mcp.Server
