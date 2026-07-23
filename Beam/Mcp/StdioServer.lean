/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Mcp.Server
import Beam.Mcp.SelfCheck
import Beam.Mcp.Stdio

open Lean

/-!
Stdio transport and concurrent request coordination for the MCP server.

`runStdio` is the only stdin reader, and every stdout message passes through `OutputSink` so JSON-RPC
messages remain serialized while independent tool calls execute concurrently.
-/

namespace Beam.Mcp.Server

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
  let trace := ← Internal.traceEnabled "LEAN_BEAM_MCP_TRACE"
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

private inductive ClientCancellationPolicy where
  | cooperative
  | nonCancellable
  deriving BEq

private structure InFlightState where
  phase : RequestPhase := .active
  runtime? : Option Beam.Broker.ServerRuntime := none
  root? : Option System.FilePath := none

private structure InFlightRequest where
  id : RequestId
  brokerId : String
  cancellationPolicy : ClientCancellationPolicy
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
    (id : RequestId)
    (cancellationPolicy : ClientCancellationPolicy) : IO (Except RpcError InFlightRequest) := do
  let request : InFlightRequest := {
    id
    brokerId := ""
    cancellationPolicy
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
  if request.cancellationPolicy == .nonCancellable then
    return (false, none)
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
                Internal.traceMcp s!"broker cancellation failed id={id.label}: {e.toString}"
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
      Internal.traceMcp s!"ignoring response for unknown server request id={response.id.label}"
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

private def Coordinator.admitToolRequest
    (coordinator : Coordinator)
    (req : Request)
    (cancellationPolicy : ClientCancellationPolicy) :
    IO (Except Json InFlightRequest) := do
  let currentState ← coordinator.protocol.get
  if !currentState.initializeComplete then
    return .error <| errorResponse req.id <|
        RpcError.invalidRequest "initialize must complete before MCP operation requests"
  if !currentState.initializedNotificationSeen then
    return .error <| errorResponse req.id <|
        RpcError.invalidRequest "notifications/initialized is required before MCP operation requests"
  match ← coordinator.registerRequest req.id cancellationPolicy with
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
    match ← Internal.handleToolCall
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
    match ← coordinator.admitToolRequest req .cooperative with
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
        Internal.traceMcp s!"request completion failed id={req.id.label}: {e.toString}"
  pure ()

private def Coordinator.handleControlToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request) : IO Unit := do
  match ← coordinator.admitToolRequest req .nonCancellable with
  | .error response => coordinator.output.send response
  | .ok request =>
      let (previous?, done) ← coordinator.pushControlBarrier
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        try
          coordinator.runToolRequest opts req request previous?
        catch e =>
          if !Beam.Mcp.Stdio.isBrokenPipeError e then
            Internal.traceMcp s!"workspace control completion failed id={req.id.label}: {e.toString}"
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
      | .error err => Internal.traceMcp s!"ignoring invalid notifications/cancelled: {err}"
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
                  errorResponse (Internal.invalidRequestId json) (RpcError.invalidRequest err)
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
    IO.println (← Internal.serverVersionText opts)
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
