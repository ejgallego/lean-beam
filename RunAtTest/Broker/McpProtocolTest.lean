/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Server
import RunAtTest.Broker.JsonAssert

open Lean
open RunAtTest.Broker.JsonAssert

namespace RunAtTest.Broker.McpProtocolTest

private def checkJsonHelpers : IO Unit := do
  require "strip LF" (Beam.Mcp.Stdio.stripLineEnding "json\n" == "json")
  require "strip CRLF" (Beam.Mcp.Stdio.stripLineEnding "json\r\n" == "json")
  require "strip CR" (Beam.Mcp.Stdio.stripLineEnding "json\r" == "json")
  require "leave interior CR" (Beam.Mcp.Stdio.stripLineEnding "j\rson" == "j\rson")

  let withField := Json.mkObj [("name", toJson "fixture")]
  let decodedName ← expectOk "optional string field" <|
    Beam.Mcp.optionalField? (α := String) withField "name"
  require "optional string field decoded" (decodedName == some "fixture")

  let missingName ← expectOk "missing optional string field" <|
    Beam.Mcp.optionalField? (α := String) withField "missing"
  require "missing optional string field decodes as none" missingName.isNone

  match Beam.Mcp.optionalField? (α := String) (Json.mkObj [("name", toJson (1 : Nat))]) "name" with
  | .ok value =>
      throw <| IO.userError s!"invalid optional field decoded unexpectedly: {repr value}"
  | .error err =>
      require "invalid optional field names the field" (err.contains "name")

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
  let some initTool := tools.find? fun tool =>
    (tool.getObjValAs? String "name").toOption == some "lean_init_workspace"
    | throw <| IO.userError s!"tools/list does not expose lean_init_workspace: {tools}"
  let initSchema ← requireObjVal "lean_init_workspace tool" "inputSchema" initTool
  requireJsonString
    "lean_init_workspace input schema"
    "$schema"
    Beam.JsonSchema.dialect
    initSchema
  requireJsonBool "lean_init_workspace input schema" "additionalProperties" false initSchema
  let initRequired ← requireObjVal "lean_init_workspace input schema" "required" initSchema
  require "lean_init_workspace should require root"
    (initRequired == toJson (#["root"] : Array String))
  let initProperties ← requireObjVal "lean_init_workspace input schema" "properties" initSchema
  let modeSchema ← requireObjVal "lean_init_workspace properties" "mode" initProperties
  let modeEnum ← requireObjVal "lean_init_workspace mode schema" "enum" modeSchema
  require "lean_init_workspace mode enum should expose set/verify/reset"
    (modeEnum == toJson (#["set", "verify", "reset"] : Array String))
  let some runAtTool := tools.find? fun tool =>
    (tool.getObjValAs? String "name").toOption == some "lean_run_at"
    | throw <| IO.userError s!"tools/list does not expose lean_run_at: {tools}"
  let runAtSchema ← requireObjVal "lean_run_at tool" "inputSchema" runAtTool
  requireJsonString
    "lean_run_at input schema"
    "$schema"
    Beam.JsonSchema.dialect
    runAtSchema
  requireJsonBool "lean_run_at input schema" "additionalProperties" false runAtSchema
  let rawExposed := tools.any fun tool =>
    (tool.getObjValAs? String "name").toOption == some RunAt.method ||
      (tool.getObjValAs? String "name").toOption == some "lean_request_at"
  require "tools/list must not expose raw LSP/request-at tools" (!rawExposed)

private def checkRootsProtocol : IO Unit := do
  let initWithoutRoots := Json.mkObj [
    ("capabilities", Json.mkObj [])
  ]
  require "empty client capabilities should not advertise roots"
    (!Beam.Mcp.clientSupportsRoots (some initWithoutRoots))

  let initWithRoots := Json.mkObj [
    ("capabilities", Json.mkObj [
      ("roots", Json.mkObj [
        ("listChanged", toJson false)
      ])
    ])
  ]
  require "roots client capability should be detected"
    (Beam.Mcp.clientSupportsRoots (some initWithRoots))

  let rootUri := (System.Uri.pathToUri (System.FilePath.mk "/tmp/lean-beam-mcp-root") : String)
  let rootsResponse (id : String) (result : Json) : Json := Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson id),
    ("result", result)
  ]
  let rootsResult (roots : Array Json) : Json := Json.mkObj [
    ("roots", Json.arr roots)
  ]
  let rpcErrorResponse := Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson Beam.Mcp.rootsListRequestId),
    ("error", Json.mkObj [
      ("code", toJson (-32603 : Int)),
      ("message", toJson "client roots failure")
    ])
  ]
  let cases : Array (String × Json × Bool) := #[
    (
      "single root",
      rootsResponse Beam.Mcp.rootsListRequestId <| rootsResult #[
        Json.mkObj [
          ("uri", toJson rootUri),
          ("name", toJson "fixture")
        ]
      ],
      true
    ),
    ("empty roots", rootsResponse Beam.Mcp.rootsListRequestId <| rootsResult #[], true),
    ("missing roots field", rootsResponse Beam.Mcp.rootsListRequestId <| Json.mkObj [], false),
    (
      "non-string root uri",
      rootsResponse Beam.Mcp.rootsListRequestId <| rootsResult #[
        Json.mkObj [
          ("uri", toJson (3 : Nat))
        ]
      ],
      false
    ),
    ("wrong response id", rootsResponse "other-roots-id" <| rootsResult #[], false),
    ("JSON-RPC roots error", rpcErrorResponse, false)
  ]
  for (label, response, shouldDecode) in cases do
    match Beam.Mcp.parseRootsListResponse response, shouldDecode with
    | .ok roots, true =>
        if label == "single root" then
          require "roots/list should decode one root" (roots.roots.size == 1)
          require "roots/list should preserve root uri" (roots.roots[0]!.uri == rootUri)
          require "roots/list should preserve root name" (roots.roots[0]!.name? == some "fixture")
    | .error _, false =>
        pure ()
    | .ok _, false =>
        throw <| IO.userError s!"{label}: roots/list response decoded unexpectedly"
    | .error err, true =>
        throw <| IO.userError s!"{label}: roots/list response failed to decode: {err}"

  let clientRoot (uri : String) (name? : Option String := none) : Beam.Mcp.ClientRoot := {
    uri
    name?
  }
  match Beam.Mcp.Roots.selectClientRoot #[clientRoot rootUri (some "fixture")] with
  | .ok root =>
      require "single client root should select /tmp root"
        (root.toString == (System.FilePath.mk "/tmp/lean-beam-mcp-root").toString)
  | .error err =>
      throw <| IO.userError s!"single client root was rejected: {err}"
  let selectCases : Array (String × Array Beam.Mcp.ClientRoot) := #[
    ("empty client roots", #[]),
    ("multiple client roots", #[clientRoot rootUri, clientRoot (System.Uri.pathToUri (System.FilePath.mk "/tmp/other") : String)]),
    ("non-file client root", #[clientRoot "https://example.com/lean-beam"])
  ]
  for (label, roots) in selectCases do
    match Beam.Mcp.Roots.selectClientRoot roots with
    | .ok root =>
        throw <| IO.userError s!"{label}: selected root unexpectedly: {root}"
    | .error _ =>
        pure ()

private def checkRuntimeSetupErrors : IO Unit := do
  let missingRoot := System.FilePath.mk s!"/tmp/lean-beam-missing-mcp-root-{← IO.monoNanosNow}"
  match ← Beam.Mcp.Runtime.mkBrokerConfig {} missingRoot with
  | .ok _ =>
      throw <| IO.userError "missing MCP root resolved unexpectedly"
  | .error err =>
      require "missing MCP root should be an invalidRequest error" (err.code == -32600)
      require "missing MCP root setup error should name the setup boundary"
        (err.message.startsWith s!"{Beam.Mcp.runtimeSetupErrorPrefix}:")
      require "missing MCP root setup error should mention project root"
        (err.message.contains "project root does not resolve")

  let root := System.FilePath.mk s!"/tmp/lean-beam-mcp-runtime-test-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    match ← Beam.Mcp.Runtime.mkBrokerConfig {} root with
    | .ok _ =>
        throw <| IO.userError "MCP runtime resolved without runtime flags or beam-cli"
    | .error err =>
        require "missing MCP runtime should be an invalidRequest error" (err.code == -32600)
        require "missing MCP runtime setup error should explain usable setup paths"
          (err.message.contains Beam.Mcp.runtimeSetupGuidance)
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def expectWorkspacePlan
    (label : String)
    (state : Beam.Workspace.InitState)
    (root : System.FilePath)
    (mode : Beam.Workspace.InitMode) : IO Beam.Workspace.InitPlan := do
  match Beam.Workspace.planInit state root mode with
  | .ok plan => pure plan
  | .error err => throw <| IO.userError s!"{label}: {err.message}"

private def expectWorkspacePlanError
    (label needle : String)
    (state : Beam.Workspace.InitState)
    (root : System.FilePath)
    (mode : Beam.Workspace.InitMode) : IO Beam.Workspace.InitError := do
  match Beam.Workspace.planInit state root mode with
  | .ok plan => throw <| IO.userError s!"{label}: expected error, got plan for {plan.root}"
  | .error err =>
      require label (err.message.contains needle)
      pure err

private def checkWorkspaceInitPolicy : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  let other := System.FilePath.mk "/other-workspace"

  let setPlan ← expectWorkspacePlan "set unbound workspace" {} root .set
  require "set unbound should create runtime" setPlan.createRuntime
  require "set unbound should not reset runtime" (!setPlan.resetCurrent)
  require "set unbound should not be already initialized" (!setPlan.alreadyInitialized)

  discard <| expectWorkspacePlanError "verify unbound workspace" "not initialized" {} root .verify

  let readyState : Beam.Workspace.InitState := {
    root? := some root
    runtimeReady := true
    workspaceUsed := false
  }
  let samePlan ← expectWorkspacePlan "set same workspace" readyState root .set
  require "same workspace should be idempotent" samePlan.alreadyInitialized
  require "same workspace should not recreate runtime" (!samePlan.createRuntime)

  let resetPlan ← expectWorkspacePlan "reset before use" readyState other .reset
  require "reset before use should create runtime" resetPlan.createRuntime
  require "reset before use should shut down current runtime" resetPlan.resetCurrent
  require "reset before use should target requested root" (resetPlan.root == other)

  let usedState := { readyState with workspaceUsed := true }
  let resetErr ← expectWorkspacePlanError "reset after use" "cannot reset" usedState other .reset
  require "reset after use should report active root" (resetErr.activeRoot? == some root)

private def expectResponse (label : String) (value : Option Json × Bool) : IO Json := do
  match value with
  | (some json, _stop) => pure json
  | (none, _stop) => throw <| IO.userError s!"{label}: expected JSON-RPC response"

private def checkServerBasics : IO Unit := do
  let root ← IO.currentDir
  let state ← Beam.Mcp.Server.ProtocolState.create (some root)
  let stdin ← IO.getStdin
  let opts : Beam.Mcp.Server.Options := {}

  let preInitResp ← expectResponse "pre-initialize tools/list rejection" =<<
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (0 : Nat)),
      ("method", toJson "tools/list")
    ])
  let preInitError ← requireObjVal "pre-initialize tools/list response" "error" preInitResp
  requireJsonInt "pre-initialize tools/list error" "code" (-32600) preInitError

  let initResp ← expectResponse "initialize" =<<
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
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
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (11 : Nat)),
      ("method", toJson "tools/list")
    ])
  let preReadyError ← requireObjVal "pre-ready tools/list response" "error" preReadyResp
  requireJsonInt "pre-ready tools/list error" "code" (-32600) preReadyError

  let initializedResp ←
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
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
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (2 : Nat)),
      ("method", toJson "tools/list")
    ])
  let listResult ← requireObjVal "tools/list response" "result" listResp
  discard <| requireObjVal "tools/list response" "tools" listResult

  let rawToolResp ← expectResponse "raw tool rejection" =<<
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
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

  let badInitResp ← expectResponse "bad init workspace input" =<<
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (31 : Nat)),
      ("method", toJson "tools/call"),
      ("params", Json.mkObj [
        ("name", toJson "lean_init_workspace"),
        ("arguments", Json.mkObj [])
      ])
    ])
  let badInitResult ← requireObjVal "bad init workspace response" "result" badInitResp
  requireJsonBool "bad init workspace result" "isError" true badInitResult
  let badInitStructured ← requireObjVal "bad init workspace result" "structuredContent" badInitResult
  requireJsonString "bad init workspace structured error" "code" "invalidInput" badInitStructured

  let relativeInitResp ← expectResponse "relative init workspace input" =<<
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson (32 : Nat)),
      ("method", toJson "tools/call"),
      ("params", Json.mkObj [
        ("name", toJson "lean_init_workspace"),
        ("arguments", Json.mkObj [
          ("root", toJson "relative/project")
        ])
      ])
    ])
  let relativeInitResult ← requireObjVal "relative init workspace response" "result" relativeInitResp
  requireJsonBool "relative init workspace result" "isError" true relativeInitResult
  let relativeInitStructured ← requireObjVal "relative init workspace result" "structuredContent" relativeInitResult
  requireJsonString "relative init workspace structured error" "code" "invalidInput" relativeInitStructured
  let relativeMessage ← IO.ofExcept <| relativeInitStructured.getObjValAs? String "message"
  require "relative init workspace error should require absolute path" (relativeMessage.contains "absolute")

  let badArgsResp ← expectResponse "bad args rejection" =<<
    Beam.Mcp.Server.handleJson state opts stdin (Json.mkObj [
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
  checkJsonHelpers
  checkIncoming
  checkToolsListShape
  checkRootsProtocol
  checkRuntimeSetupErrors
  checkWorkspaceInitPolicy
  checkServerBasics

end RunAtTest.Broker.McpProtocolTest

def main := RunAtTest.Broker.McpProtocolTest.main
