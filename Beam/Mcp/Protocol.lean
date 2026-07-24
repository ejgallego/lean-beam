/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Json
import Beam.Mcp.Projection
import Beam.Version

open Lean

namespace Beam.Mcp

/--
MCP protocol revision advertised by `lean-beam-mcp`.

This is the only revision currently implemented and tested by the repository.
-/
def protocolVersion : String :=
  Beam.Version.mcpProtocolVersion

def serverName : String :=
  Beam.Version.mcpServerName

def serverVersion : String :=
  Beam.Version.projectVersion

structure RpcError where
  code : Int
  message : String
  data? : Option Json := none
  deriving FromJson, ToJson

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

inductive RequestId where
  | string (value : String)
  | number (value : JsonNumber)
  deriving BEq, Repr

namespace RequestId

def fromJson? : Json → Except String RequestId
  | .str value => pure <| .string value
  | .num value => pure <| .number value
  | _ => throw "request id must be a string or number"

def json : RequestId → Json
  | .string value => .str value
  | .number value => .num value

instance : Coe RequestId Json where
  coe := json

def label : RequestId → String
  | .string value => value
  | id => id.json.compress

def compare : RequestId → RequestId → Ordering
  | .string left, .string right => Ord.compare left right
  | .string _, .number _ => .lt
  | .number _, .string _ => .gt
  | .number left, .number right =>
      (Ord.compare left.mantissa right.mantissa).then <| Ord.compare left.exponent right.exponent

instance : Ord RequestId where
  compare := compare

end RequestId

structure Request where
  id : RequestId
  method : String
  params? : Option Json := none

structure Notification where
  method : String
  params? : Option Json := none

inductive IncomingResponseOutcome where
  | result (value : Json)
  | error (value : RpcError)

structure IncomingResponse where
  id : RequestId
  outcome : IncomingResponseOutcome

structure CancelledParams where
  requestId : RequestId
  reason? : Option String := none

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
  | response (response : IncomingResponse)

def Incoming.fromJson? (json : Json) : Except String Incoming := do
  let version ← json.getObjValAs? String "jsonrpc"
  if version != "2.0" then
    throw "expected jsonrpc=\"2.0\""
  match json.getObjVal? "method" with
  | .ok _ =>
      let method ← json.getObjValAs? String "method"
      let params? ← optionalField? (α := Json) json "params"
      match json.getObjVal? "id" with
      | .ok id =>
          pure <| .request { id := ← RequestId.fromJson? id, method, params? }
      | .error _ =>
          pure <| .notification { method, params? }
  | .error _ =>
      let id ← RequestId.fromJson? (← json.getObjVal? "id")
      let result? ← optionalField? (α := Json) json "result"
      let error? ← optionalField? (α := RpcError) json "error"
      match result?, error? with
      | some result, none =>
          pure <| .response { id, outcome := .result result }
      | none, some error =>
          pure <| .response { id, outcome := .error error }
      | none, none =>
          throw "JSON-RPC response must contain exactly one of result or error"
      | some _, some _ =>
          throw "JSON-RPC response must not contain both result and error"

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

def parseCancelledParams (params? : Option Json) : Except String CancelledParams := do
  let params ←
    match params? with
    | some params => requireObject "notifications/cancelled params" params
    | none => throw "notifications/cancelled params are required"
  let requestId ← RequestId.fromJson? (← params.getObjVal? "requestId")
  let reason? ← optionalField? (α := String) params "reason"
  pure { requestId, reason? }

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
  progressToken? : Option Json := none

def validProgressToken : Json → Bool
  | .str _ => true
  | token@(.num _) =>
      match token.getInt? with
      | .ok _ => true
      | .error _ => false
  | _ => false

private def parseProgressToken? (params : Json) : Except String (Option Json) := do
  let metaJson ←
    match params.getObjVal? "_meta" with
    | .ok rawMeta => requireObject "tools/call params _meta" rawMeta
    | .error _ => pure (Json.mkObj [])
  match metaJson.getObjVal? "progressToken" with
  | .ok token =>
      if validProgressToken token then
        pure <| some token
      else
        throw "tools/call params _meta.progressToken must be a string or integer"
  | .error _ =>
      pure none

def parseCallToolParams (params? : Option Json) : Except String CallToolParams := do
  let params ←
    match params? with
    | some params => requireObject "tools/call params" params
    | none => throw "tools/call params are required"
  let rawName ← params.getObjVal? "name"
  let name ← fromJson? (α := ToolName) rawName
  let progressToken? ← parseProgressToken? params
  let arguments ←
    match params.getObjVal? "arguments" with
    | .ok arguments => requireObject "tools/call arguments" arguments
    | .error _ => pure (Json.mkObj [])
  pure { name, arguments, progressToken? }

def progressNotification
    (progressToken : Json)
    (progress : Nat)
    (message? : Option String := none)
    (total? : Option Nat := none) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson "notifications/progress"),
    ("params", Json.mkObj <|
      [
        ("progressToken", progressToken),
        ("progress", toJson progress)
      ] ++
      (match total? with
      | some total => [("total", toJson total)]
      | none => []) ++
      (match message? with
      | some message => [("message", toJson message)]
      | none => []))
  ]

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
