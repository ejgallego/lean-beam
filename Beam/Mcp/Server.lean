/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Lean.Workspace
import Beam.Mcp.Options
import Beam.Mcp.Protocol
import Beam.Mcp.Runtime
import Beam.Mcp.Roots
import Beam.Mcp.SelfCheck
import Beam.Mcp.Stdio
import Beam.Workspace

open Lean

namespace Beam.Mcp.Server

structure ProtocolState where
  initializeComplete : Bool := false
  initializedNotificationSeen : Bool := false
  clientSupportsRoots : Bool := false
  root? : Option System.FilePath := none
  rootError? : Option String := none
  runtime? : Option Beam.Broker.ServerRuntime := none
  workspaceUsed : Bool := false

def ProtocolState.create (root? : Option System.FilePath := none) : IO (IO.Ref ProtocolState) :=
  IO.mkRef { root? }

private def ProtocolState.initState (state : ProtocolState) : Beam.Workspace.InitState := {
  root? := state.root?
  runtimeReady := state.runtime?.isSome
  workspaceUsed := state.workspaceUsed
}

abbrev Options := Beam.Mcp.Options

private def writeJsonLine (json : Json) : IO Unit := do
  Beam.Mcp.Stdio.writeStdoutJsonLine json

private def invalidRequestId (json : Json) : Json :=
  match json.getObjVal? "id" with
  | .ok id =>
      if validRequestId id then id else Json.null
  | .error _ => Json.null

private def brokerClientRequestId (req : Request) : String :=
  s!"mcp:{requestIdLabel req.id}"

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
    (stdin : IO.FS.Stream) : IO (Except RpcError System.FilePath) := do
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
              Roots.requestClientRoot stdin writeJsonLine
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
    (stdin : IO.FS.Stream) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  let currentState ← state.get
  match currentState.runtime?, currentState.root? with
  | some runtime, some root =>
      pure <| .ok (runtime, root)
  | _, _ =>
      match ← ensureRoot state stdin with
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

private def handleInitWorkspace
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (arguments : Json) : IO Json := do
  let input ←
    match fromJson? (α := InitWorkspaceInput) arguments with
    | .ok input => pure input
    | .error err => return callToolErrorResult <| ToolError.invalidInput err
  let requestedRoot ←
    match ← Beam.Lean.Workspace.resolveRoot input.root with
    | .ok root => pure root
    | .error err => return callToolErrorResult <| workspaceErrorToToolError err
  let mode := input.mode
  let currentState ← state.get
  let plan ←
    match Beam.Workspace.planInit currentState.initState requestedRoot mode with
    | .ok plan => pure plan
    | .error err => return callToolErrorResult <| workspaceErrorToToolError err
  if plan.resetCurrent then
    match currentState.runtime? with
    | some runtime =>
        match ← shutdownRuntimeForReset runtime with
        | .ok () => pure ()
        | .error err => return callToolErrorResult err
    | none =>
        pure ()
  if !plan.createRuntime then
    return callToolResult <| toJson <| Beam.Workspace.initResult plan
  match ← createRuntimeForRoot opts requestedRoot with
  | .error err =>
      return callToolErrorResult <| ToolError.runtimeSetup err.message
  | .ok (runtime, root) =>
      state.set {
        currentState with
          root? := some root
          rootError? := none
          runtime? := some runtime
          workspaceUsed := false
      }
      pure <| callToolResult <| toJson <| Beam.Workspace.initResult plan root

private def brokerRequestForTool
    (root : System.FilePath)
    (params : CallToolParams)
    (clientRequestId : String) : Except String Beam.Broker.Request := do
  let req ← params.name.toBrokerRequest root.toString params.arguments
  pure { req with clientRequestId? := some clientRequestId }

private def handleToolCall
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request) : IO (Except RpcError Json) := do
  let params ←
    match parseCallToolParams req.params? with
    | .ok params => pure params
    | .error err => return .error <| RpcError.invalidParams err
  if params.name == .leanInitWorkspace then
    return .ok (← handleInitWorkspace state opts params.arguments)
  let root ←
    match ← ensureRoot state stdin with
    | .ok root => pure root
    | .error err => return .error err
  let brokerReq ←
    match brokerRequestForTool root params (brokerClientRequestId req) with
    | .ok brokerReq => pure brokerReq
    | .error err => return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let (runtime, _root) ←
    match ← ensureRuntime state opts stdin with
    | .ok runtimeAndRoot => pure runtimeAndRoot
    | .error err => return .error err
  state.modify fun state => { state with workspaceUsed := true }
  let (brokerResp, _) ← runtime.dispatchRequest brokerReq
  match normalizeBrokerResponse params.name brokerResp with
  | .ok result =>
      pure <| .ok <| callToolResult <| Beam.Workspace.addActiveRoot root result
  | .error err =>
      pure <| .ok <| callToolErrorResult err

private def handleReadyOperationRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request) : IO (Json × Bool) := do
  match req.method with
  | "tools/list" =>
      pure (successResponse req.id toolsListResult, false)
  | "tools/call" =>
      match ← handleToolCall state opts stdin req with
      | .ok result => pure (successResponse req.id result, false)
      | .error err => pure (errorResponse req.id err, false)
  | method =>
      pure (errorResponse req.id (RpcError.methodNotFound method), false)

def handleRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request) : IO (Json × Bool) := do
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
        handleReadyOperationRequest state opts stdin req
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
    (stdin : IO.FS.Stream)
    (json : Json) : IO (Option Json × Bool) := do
  match Incoming.fromJson? json with
  | .ok (.request req) =>
      let (resp, stop) ← handleRequest state opts stdin req
      pure (some resp, stop)
  | .ok (.notification notification) =>
      let stop ← handleNotification state notification
      pure (none, stop)
  | .error err =>
      pure (some <| errorResponse (invalidRequestId json) (RpcError.invalidRequest err), false)

partial def runStdio (opts : Options) (root? : Option System.FilePath) : IO Unit := do
  let stdin ← IO.getStdin
  let state ← ProtocolState.create root?
  let rec loop : IO Unit := do
    let line := Beam.Mcp.Stdio.stripLineEnding (← stdin.getLine)
    if line.isEmpty then
      pure ()
    else
      match Json.parse line with
      | .error err =>
          writeJsonLine <| errorResponse Json.null (RpcError.parseError err)
          loop
      | .ok json =>
          let (response?, stop) ← handleJson state opts stdin json
          match response? with
          | some response => writeJsonLine response
          | none => pure ()
          unless stop do
            loop
  try
    loop
  catch e =>
    if Beam.Mcp.Stdio.isBrokenPipeError e then
      pure ()
    else
      throw e

def main (args : List String) : IO Unit := do
  let opts ←
    match Beam.Mcp.parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  match opts.selfCheckPath? with
  | some path =>
      SelfCheck.run {
        root? := opts.root?
        leanCmd? := opts.leanCmd?
        leanPlugin? := opts.leanPlugin?
        beamCli? := opts.beamCli?
      } path
  | none =>
      let root? ← opts.root?.mapM (fun root => IO.FS.realPath <| System.FilePath.mk root)
      runStdio opts root?

end Beam.Mcp.Server
