/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Mcp.Protocol

open Lean

namespace Beam.Mcp.Server

structure ProtocolState where
  initializeComplete : Bool := false
  initializedNotificationSeen : Bool := false
  clientSupportsRoots : Bool := false
  root? : Option System.FilePath := none
  rootError? : Option String := none
  runtime? : Option Beam.Broker.ServerRuntime := none

def ProtocolState.create (root? : Option System.FilePath := none) : IO (IO.Ref ProtocolState) :=
  IO.mkRef { root? }

structure Options where
  root? : Option String := none
  leanCmd? : Option String := none
  leanPlugin? : Option String := none

private def usage : String :=
  String.intercalate "\n" [
    "usage: lean-beam-mcp [--root PATH] [--lean-cmd CMD] [--lean-plugin PATH]",
    "",
    "Runs the experimental Lean Beam MCP server over newline-delimited JSON-RPC on stdio.",
    "When --root is omitted, the server discovers exactly one project root via MCP roots/list.",
    "Only curated Lean tools are exposed; raw LSP and broker escape hatches are intentionally absent."
  ]

private partial def parseOptions (opts : Options) : List String → Except String Options
  | [] => pure opts
  | "--root" :: root :: rest =>
      parseOptions { opts with root? := some root } rest
  | "--lean-cmd" :: leanCmd :: rest =>
      parseOptions { opts with leanCmd? := some leanCmd } rest
  | "--lean-plugin" :: leanPlugin :: rest =>
      parseOptions { opts with leanPlugin? := some leanPlugin } rest
  | "-h" :: _ | "--help" :: _ =>
      throw usage
  | arg :: _ =>
      throw s!"unexpected lean-beam-mcp argument '{arg}'\n\n{usage}"

private def mkBrokerConfig (opts : Options) (root : System.FilePath) : IO Beam.Broker.BrokerConfig := do
  let root ← IO.FS.realPath root
  let leanPlugin? ← opts.leanPlugin?.mapM (fun path => IO.FS.realPath <| System.FilePath.mk path)
  pure {
    root := root
    leanCmd? := opts.leanCmd?
    leanPlugin? := leanPlugin?
  }

def stripLineEnding (line : String) : String :=
  let line :=
    if !line.isEmpty && line.back == '\n' then
      line.dropEnd 1 |>.copy
    else
      line
  if !line.isEmpty && line.back == '\r' then
    line.dropEnd 1 |>.copy
  else
    line

private def writeJsonLine (json : Json) : IO Unit := do
  let stdout ← IO.getStdout
  stdout.putStr (json.compress ++ "\n")
  stdout.flush

private def invalidRequestId (json : Json) : Json :=
  match json.getObjVal? "id" with
  | .ok id =>
      if validRequestId id then id else Json.null
  | .error _ => Json.null

private def brokerClientRequestId (req : Request) : String :=
  s!"mcp:{requestIdLabel req.id}"

private def rootsUnsupportedMessage : String :=
  "MCP client did not advertise roots; start lean-beam-mcp with --root PATH or enable the client's roots capability"

private def selectClientRoot (roots : Array ClientRoot) : Except String System.FilePath := do
  if roots.size == 0 then
    throw "MCP client returned no roots; start lean-beam-mcp with --root PATH or configure exactly one project root"
  else if roots.size > 1 then
    throw "MCP client returned multiple roots; start lean-beam-mcp with --root PATH until multi-root selection is supported"
  else
    let root := roots[0]!
    match System.Uri.fileUriToPath? root.uri with
    | some path => pure path
    | none => throw s!"MCP client root URI must be a file:// URI, got {root.uri}"

private partial def requestClientRoot (stdin : IO.FS.Stream) : IO (Except String System.FilePath) := do
  try
    writeJsonLine rootsListRequest
    let rec waitForResponse : IO (Except String System.FilePath) := do
      let line := stripLineEnding (← stdin.getLine)
      if line.isEmpty then
        pure <| .error "MCP client closed stdin before answering roots/list"
      else
        match Json.parse line with
        | .error err =>
            pure <| .error s!"MCP client roots/list response is not valid JSON: {err}"
        | .ok json =>
            match json.getObjVal? "method" with
            | .ok _ =>
                match Incoming.fromJson? json with
                | .ok (.request req) =>
                    writeJsonLine <|
                      errorResponse req.id <|
                        RpcError.invalidRequest "cannot process client request while waiting for roots/list response"
                    waitForResponse
                | .ok (.notification notification) =>
                    if notification.method == "exit" then
                      pure <| .error "MCP client exited before answering roots/list"
                    else
                      waitForResponse
                | .error err =>
                    pure <| .error err
            | .error _ =>
                match parseRootsListResponse json with
                | .error err => pure <| .error err
                | .ok result =>
                    match selectClientRoot result.roots with
                    | .error err => pure <| .error err
                    | .ok root =>
                        let root ← IO.FS.realPath root
                        pure <| .ok root
    waitForResponse
  catch e =>
    pure <| .error e.toString

private def ensureRuntime
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  let currentState ← state.get
  match currentState.runtime?, currentState.root? with
  | some runtime, some root =>
      pure <| .ok (runtime, root)
  | _, _ =>
      match currentState.rootError? with
      | some err =>
          pure <| .error <| RpcError.invalidRequest err
      | none =>
          let root? ←
            match currentState.root? with
            | some root => pure <| .ok root
            | none =>
                if currentState.clientSupportsRoots then
                  requestClientRoot stdin
                else
                  pure <| .error rootsUnsupportedMessage
          match root? with
          | .error err =>
              state.modify fun state => { state with rootError? := some err }
              pure <| .error <| RpcError.invalidRequest err
          | .ok root =>
              let config ← mkBrokerConfig opts root
              let runtime ← Beam.Broker.ServerRuntime.create config
              state.modify fun state => { state with root? := some config.root, runtime? := some runtime }
              pure <| .ok (runtime, config.root)

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
  let (runtime, root) ←
    match ← ensureRuntime state opts stdin with
    | .ok runtimeAndRoot => pure runtimeAndRoot
    | .error err => return .error err
  let brokerReq ←
    match brokerRequestForTool root params (brokerClientRequestId req) with
    | .ok brokerReq => pure brokerReq
    | .error err => return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let (brokerResp, _) ← runtime.dispatchRequest brokerReq
  match normalizeBrokerResponse params.name brokerResp with
  | .ok result =>
      pure <| .ok <| callToolResult result
  | .error err =>
      pure <| .ok <| callToolErrorResult err

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
        match req.method with
        | "tools/list" =>
            pure (successResponse req.id toolsListResult, false)
        | "tools/call" =>
            match ← handleToolCall state opts stdin req with
            | .ok result => pure (successResponse req.id result, false)
            | .error err => pure (errorResponse req.id err, false)
        | _ =>
            unreachable!
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
    let line := stripLineEnding (← stdin.getLine)
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
  loop

def main (args : List String) : IO Unit := do
  let opts ←
    match parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  let root? ← opts.root?.mapM (fun root => IO.FS.realPath <| System.FilePath.mk root)
  runStdio opts root?

end Beam.Mcp.Server
