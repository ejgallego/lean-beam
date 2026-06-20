/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Json
import Beam.Mcp.Projection

open Lean

namespace Beam.Mcp

/--
MCP protocol revision advertised by `lean-beam-mcp`.

This is the only revision currently implemented and tested by the repository.
-/
def protocolVersion : String :=
  "2025-11-25"

def serverName : String :=
  "lean-beam-mcp"

def serverVersion : String :=
  "0.1.0-alpha"

structure RpcError where
  code : Int
  message : String
  data? : Option Json := none
  deriving ToJson

namespace RpcError

def parseError (message : String) : RpcError :=
  { code := -32700, message }

def invalidRequest (message : String) : RpcError :=
  { code := -32600, message }

def methodNotFound (method : String) : RpcError :=
  { code := -32601, message := s!"method not found: {method}" }

def invalidParams (message : String) : RpcError :=
  { code := -32602, message }

def internalError (message : String) : RpcError :=
  { code := -32603, message }

end RpcError

def validRequestId : Json → Bool
  | .str _ => true
  | .num _ => true
  | _ => false

def requestIdLabel : Json → String
  | .str s => s
  | id => id.compress

structure Request where
  id : Json
  method : String
  params? : Option Json := none

structure Notification where
  method : String
  params? : Option Json := none

structure ClientRoot where
  uri : String
  name? : Option String := none
  deriving Inhabited

instance : FromJson ClientRoot where
  fromJson? json := do
    let uri ← json.getObjValAs? String "uri"
    let name? ← optionalField? (α := String) json "name"
    pure { uri, name? }

structure ListRootsResult where
  roots : Array ClientRoot

instance : FromJson ListRootsResult where
  fromJson? json := do
    let roots ← json.getObjValAs? (Array ClientRoot) "roots"
    pure { roots }

inductive Incoming where
  | request (request : Request)
  | notification (notification : Notification)

def Incoming.fromJson? (json : Json) : Except String Incoming := do
  let version ← json.getObjValAs? String "jsonrpc"
  if version != "2.0" then
    throw "expected jsonrpc=\"2.0\""
  let method ← json.getObjValAs? String "method"
  let params? ← optionalField? (α := Json) json "params"
  match json.getObjVal? "id" with
  | .ok id =>
      if validRequestId id then
        pure <| .request { id, method, params? }
      else
        throw "request id must be a string or number"
  | .error _ =>
      pure <| .notification { method, params? }

def clientSupportsRoots (params? : Option Json) : Bool :=
  match params? with
  | none => false
  | some params =>
      match params.getObjVal? "capabilities" with
      | .error _ => false
      | .ok capabilities =>
          match capabilities.getObjVal? "roots" with
          | .ok _ => true
          | .error _ => false

def rootsListRequestId : String :=
  "lean-beam-roots-1"

def rootsListRequest : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson rootsListRequestId),
    ("method", toJson "roots/list")
  ]

def requireObject (label : String) : Json → Except String Json
  | obj@(.obj _) => pure obj
  | other => throw s!"{label} must be an object, got {other.compress}"

inductive LogLevel where
  | debug
  | info
  | notice
  | warning
  | error
  | critical
  | alert
  | emergency
  deriving BEq, Repr

def LogLevel.key : LogLevel → String
  | .debug => "debug"
  | .info => "info"
  | .notice => "notice"
  | .warning => "warning"
  | .error => "error"
  | .critical => "critical"
  | .alert => "alert"
  | .emergency => "emergency"

def LogLevel.severityRank : LogLevel → Nat
  | .emergency => 0
  | .alert => 1
  | .critical => 2
  | .error => 3
  | .warning => 4
  | .notice => 5
  | .info => 6
  | .debug => 7

def LogLevel.allows (minimum event : LogLevel) : Bool :=
  event.severityRank <= minimum.severityRank

instance : ToJson LogLevel where
  toJson level := toJson level.key

instance : FromJson LogLevel where
  fromJson?
    | .str "debug" => .ok .debug
    | .str "info" => .ok .info
    | .str "notice" => .ok .notice
    | .str "warning" => .ok .warning
    | .str "error" => .ok .error
    | .str "critical" => .ok .critical
    | .str "alert" => .ok .alert
    | .str "emergency" => .ok .emergency
    | j => .error s!"expected MCP log level, got {j.compress}"

structure SetLogLevelParams where
  level : LogLevel
  deriving FromJson

def parseSetLogLevelParams (params? : Option Json) : Except String LogLevel := do
  let params ←
    match params? with
    | some params => requireObject "logging/setLevel params" params
    | none => throw "logging/setLevel params are required"
  let decoded ← fromJson? (α := SetLogLevelParams) params
  pure decoded.level

def notification (method : String) (params : Json) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson method),
    ("params", params)
  ]

def logMessageNotification (level : LogLevel) (logger : String) (data : Json) : Json :=
  notification "notifications/message" <| Json.mkObj [
    ("level", toJson level),
    ("logger", toJson logger),
    ("data", data)
  ]

def parseRootsListResponse (json : Json) : Except String ListRootsResult := do
  let version ← json.getObjValAs? String "jsonrpc"
  if version != "2.0" then
    throw "expected jsonrpc=\"2.0\""
  let id ← json.getObjValAs? String "id"
  if id != rootsListRequestId then
    throw s!"expected roots/list response id {rootsListRequestId}, got {id}"
  match json.getObjVal? "error" with
  | .ok err =>
      throw s!"roots/list failed: {err.compress}"
  | .error _ =>
      pure ()
  let result ← json.getObjVal? "result"
  fromJson? result

def successResponse (id : Json) (result : Json) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", id),
    ("result", result)
  ]

def errorResponse (id : Json) (err : RpcError) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", id),
    ("error", toJson err)
  ]

def initializeResult : Json :=
  Json.mkObj [
    ("protocolVersion", toJson protocolVersion),
    ("capabilities", Json.mkObj [
      ("logging", Json.mkObj []),
      ("tools", Json.mkObj [
        ("listChanged", toJson false)
      ])
    ]),
    ("serverInfo", Json.mkObj [
      ("name", toJson serverName),
      ("version", toJson serverVersion)
    ])
  ]

def toolDescriptorJson (desc : ToolDescriptor) : Json :=
  Json.mkObj [
    ("name", toJson desc.name),
    ("description", toJson desc.description),
    ("inputSchema", desc.inputSchema)
  ]

def toolsListResult : Json :=
  Json.mkObj [
    ("tools", toJson <| toolDescriptors.map toolDescriptorJson)
  ]

structure CallToolParams where
  name : ToolName
  arguments : Json := Json.mkObj []

def parseCallToolParams (params? : Option Json) : Except String CallToolParams := do
  let params ←
    match params? with
    | some params => requireObject "tools/call params" params
    | none => throw "tools/call params are required"
  let rawName ← params.getObjVal? "name"
  let name ← fromJson? (α := ToolName) rawName
  let arguments ←
    match params.getObjVal? "arguments" with
    | .ok arguments => requireObject "tools/call arguments" arguments
    | .error _ => pure (Json.mkObj [])
  pure { name, arguments }

private def textContent (text : String) : Json :=
  Json.mkObj [
    ("type", toJson "text"),
    ("text", toJson text)
  ]

def callToolResult (structured : Json) (isError : Bool := false) : Json :=
  Json.mkObj [
    ("content", Json.arr #[textContent structured.compress]),
    ("structuredContent", structured),
    ("isError", toJson isError)
  ]

def toolErrorJson (err : ToolError) : Json :=
  Json.mkObj <|
    [
      ("code", toJson err.code),
      ("message", toJson err.message)
    ] ++
    match err.data? with
    | some data => [("data", data)]
    | none => []

def callToolErrorResult (err : ToolError) : Json :=
  callToolResult (toolErrorJson err) (isError := true)

end Beam.Mcp
