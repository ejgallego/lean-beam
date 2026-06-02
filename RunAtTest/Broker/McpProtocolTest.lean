/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Server

open Lean

namespace RunAtTest.Broker.McpProtocolTest

private def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

private def requireObjVal (label field : String) (json : Json) : IO Json := do
  match json.getObjVal? field with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label}: missing field {field}: {err}\n{json.compress}"

private def requireJsonString (label field expected : String) (json : Json) : IO Unit := do
  match json.getObjValAs? String field with
  | .ok actual =>
      if actual != expected then
        throw <| IO.userError s!"{label}: expected {field}={expected}, got {json.compress}"
  | .error err =>
      throw <| IO.userError s!"{label}: invalid string field {field}: {err}\n{json.compress}"

private def requireJsonInt (label field : String) (expected : Int) (json : Json) : IO Unit := do
  match json.getObjValAs? Int field with
  | .ok actual =>
      if actual != expected then
        throw <| IO.userError s!"{label}: expected {field}={expected}, got {json.compress}"
  | .error err =>
      throw <| IO.userError s!"{label}: invalid int field {field}: {err}\n{json.compress}"

private def requireJsonBool (label field : String) (expected : Bool) (json : Json) : IO Unit := do
  match json.getObjValAs? Bool field with
  | .ok actual =>
      if actual != expected then
        throw <| IO.userError s!"{label}: expected {field}={expected}, got {json.compress}"
  | .error err =>
      throw <| IO.userError s!"{label}: invalid bool field {field}: {err}\n{json.compress}"

private def expectOk (label : String) (result : Except String α) : IO α := do
  match result with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label}: {err}"

private def checkIncoming : IO Unit := do
  let reqJson := Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (1 : Nat)),
    ("method", toJson "tools/list")
  ]
  match ← expectOk "decode request" <| Beam.Mcp.Incoming.fromJson? reqJson with
  | .request req =>
      require "decoded request method" (req.method == "tools/list")
  | .notification _ =>
      throw <| IO.userError "request decoded as notification"

  let notificationJson := Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson "notifications/initialized")
  ]
  match ← expectOk "decode notification" <| Beam.Mcp.Incoming.fromJson? notificationJson with
  | .notification notification =>
      require "decoded notification method" (notification.method == "notifications/initialized")
  | .request _ =>
      throw <| IO.userError "notification decoded as request"

  match Beam.Mcp.Incoming.fromJson? <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", Json.null),
    ("method", toJson "tools/list")
  ] with
  | .ok _ =>
      throw <| IO.userError "null request id decoded successfully"
  | .error _ =>
      pure ()

private def checkToolsListShape : IO Unit := do
  let result := Beam.Mcp.toolsListResult
  let tools ← requireObjVal "tools/list result" "tools" result
  let Json.arr tools := tools
    | throw <| IO.userError s!"tools/list tools is not an array: {tools.compress}"
  require "tools/list is non-empty" (!tools.isEmpty)
  let some runAtTool := tools.find? fun tool =>
    (tool.getObjValAs? String "name").toOption == some "lean_run_at"
    | throw <| IO.userError s!"tools/list does not expose lean_run_at: {tools}"
  let runAtSchema ← requireObjVal "lean_run_at tool" "inputSchema" runAtTool
  requireJsonString
    "lean_run_at input schema"
    "$schema"
    "https://json-schema.org/draft/2020-12/schema"
    runAtSchema
  let rawExposed := tools.any fun tool =>
    (tool.getObjValAs? String "name").toOption == some RunAt.method ||
      (tool.getObjValAs? String "name").toOption == some "lean_request_at"
  require "tools/list must not expose raw LSP/request-at tools" (!rawExposed)

private def mkRuntime : IO Beam.Broker.ServerRuntime := do
  let root ← IO.currentDir
  Beam.Broker.ServerRuntime.create { root := root }

private def expectResponse (label : String) (value : Option Json × Bool) : IO Json := do
  match value with
  | (some json, _stop) => pure json
  | (none, _stop) => throw <| IO.userError s!"{label}: expected JSON-RPC response"

private def checkServerBasics : IO Unit := do
  let runtime ← mkRuntime
  let root ← IO.currentDir
  let state ← Beam.Mcp.Server.ProtocolState.create

  let preInitResp ← expectResponse "pre-initialize tools/list rejection" =<<
    Beam.Mcp.Server.handleJson state runtime root (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (0 : Nat)),
      ("method", toJson "tools/list")
    ])
  let preInitError ← requireObjVal "pre-initialize tools/list response" "error" preInitResp
  requireJsonInt "pre-initialize tools/list error" "code" (-32600) preInitError

  let initResp ← expectResponse "initialize" =<<
    Beam.Mcp.Server.handleJson state runtime root (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (1 : Nat)),
      ("method", toJson "initialize"),
      ("params", Json.mkObj [
        ("protocolVersion", toJson Beam.Mcp.protocolVersion),
        ("capabilities", Json.mkObj [])
      ])
    ])
  let initResult ← requireObjVal "initialize response" "result" initResp
  requireJsonString "initialize result" "protocolVersion" Beam.Mcp.protocolVersion initResult
  let capabilities ← requireObjVal "initialize result" "capabilities" initResult
  let toolsCapability ← requireObjVal "initialize capabilities" "tools" capabilities
  requireJsonBool "initialize tools capability" "listChanged" false toolsCapability

  let preReadyResp ← expectResponse "pre-ready tools/list rejection" =<<
    Beam.Mcp.Server.handleJson state runtime root (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (11 : Nat)),
      ("method", toJson "tools/list")
    ])
  let preReadyError ← requireObjVal "pre-ready tools/list response" "error" preReadyResp
  requireJsonInt "pre-ready tools/list error" "code" (-32600) preReadyError

  let initializedResp ←
    Beam.Mcp.Server.handleJson state runtime root (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("method", toJson "notifications/initialized")
    ])
  match initializedResp with
  | (none, false) => pure ()
  | (some json, stop) =>
      throw <| IO.userError s!"initialized notification should not produce a response/stop: {json.compress}, {stop}"
  | (none, true) =>
      throw <| IO.userError "initialized notification should not stop the server"

  let listResp ← expectResponse "tools/list" =<<
    Beam.Mcp.Server.handleJson state runtime root (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (2 : Nat)),
      ("method", toJson "tools/list")
    ])
  let listResult ← requireObjVal "tools/list response" "result" listResp
  discard <| requireObjVal "tools/list response" "tools" listResult

  let rawToolResp ← expectResponse "raw tool rejection" =<<
    Beam.Mcp.Server.handleJson state runtime root (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (3 : Nat)),
      ("method", toJson "tools/call"),
      ("params", Json.mkObj [
        ("name", toJson RunAt.method),
        ("arguments", Json.mkObj [])
      ])
    ])
  let rawToolError ← requireObjVal "raw tool response" "error" rawToolResp
  requireJsonInt "raw tool error" "code" (-32602) rawToolError

  let badArgsResp ← expectResponse "bad args rejection" =<<
    Beam.Mcp.Server.handleJson state runtime root (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (4 : Nat)),
      ("method", toJson "tools/call"),
      ("params", Json.mkObj [
        ("name", toJson "lean_run_at"),
        ("arguments", Json.mkObj [
          ("path", toJson "Demo.lean"),
          ("line", toJson (0 : Nat)),
          ("character", toJson (0 : Nat))
        ])
      ])
    ])
  let badArgsResult ← requireObjVal "bad args response" "result" badArgsResp
  requireJsonBool "bad args result" "isError" true badArgsResult
  let badArgsStructured ← requireObjVal "bad args result" "structuredContent" badArgsResult
  requireJsonString "bad args structured error" "code" "invalidInput" badArgsStructured

def main : IO Unit := do
  checkIncoming
  checkToolsListShape
  checkServerBasics

end RunAtTest.Broker.McpProtocolTest

def main := RunAtTest.Broker.McpProtocolTest.main
