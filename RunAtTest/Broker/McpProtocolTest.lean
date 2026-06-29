/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Server
import RunAtTest.Broker.JsonAssert
import RunAtTest.Broker.TestUtil
import RunAtTest.TestHarness

open Lean
open RunAtTest.Broker.JsonAssert
open RunAtTest.Broker.TestUtil

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

private def requireJsonArray (label : String) : Json → IO (Array Json)
  | Json.arr values => pure values
  | other => throw <| IO.userError s!"{label} is not an array: {other.compress}"

private def requireTool (tools : Array Json) (name : String) : IO Json := do
  let some tool := tools.find? fun tool =>
      (tool.getObjValAs? String "name").toOption == some name
    | throw <| IO.userError s!"tools/list does not expose {name}: {tools}"
  pure tool

private def requireClosedInputSchema (label : String) (tool : Json) : IO Json := do
  let schema ← requireObjVal label "inputSchema" tool
  requireJsonString label "$schema" Beam.JsonSchema.dialect schema
  requireJsonBool label "additionalProperties" false schema
  pure schema

private def requireSchemaRequiredFields
    (label : String)
    (expected : Array String)
    (schema : Json) : IO Unit := do
  let required ← requireObjVal label "required" schema
  require s!"{label} required fields" (required == toJson expected)

private def checkToolsListShape : IO Unit := do
  let result := Beam.Mcp.toolsListResult
  let tools ← requireObjVal "tools/list result" "tools" result
  let tools ← requireJsonArray "tools/list tools" tools
  require "tools/list is non-empty" (!tools.isEmpty)
  let initTool ← requireTool tools "lean_init_workspace"
  let initSchema ← requireClosedInputSchema "lean_init_workspace input schema" initTool
  requireSchemaRequiredFields "lean_init_workspace input schema" #["root"] initSchema
  let initProperties ← requireObjVal "lean_init_workspace input schema" "properties" initSchema
  let modeSchema ← requireObjVal "lean_init_workspace properties" "mode" initProperties
  let modeEnum ← requireObjVal "lean_init_workspace mode schema" "enum" modeSchema
  require "lean_init_workspace mode enum should expose set/verify/reset"
    (modeEnum == toJson (#["set", "verify", "reset"] : Array String))
  let modeDescription ← IO.ofExcept <| modeSchema.getObjValAs? String "description"
  require "lean_init_workspace mode description should explain destructive reset"
    (modeDescription.contains "invalidates handles")
  require "MCP capability names should include central Lean tools"
    (Beam.Mcp.capabilityNames.contains "lean_run_at" &&
      Beam.Mcp.capabilityNames.contains "lean_update" &&
      Beam.Mcp.capabilityNames.contains "lean_sync" &&
      Beam.Mcp.capabilityNames.contains "lean_save" &&
      Beam.Mcp.capabilityNames.contains "lean_goals_prev" &&
      Beam.Mcp.capabilityNames.contains "lean_goals_after")
  require "MCP capability names should not expose raw LSP methods"
    (!Beam.Mcp.capabilityNames.contains RunAt.method)

  let schemaCases : Array (String × Array String) := #[
    ("lean_run_at", #["path", "version", "line", "character", "text"]),
    ("lean_run_at_handle", #["path", "version", "line", "character", "text"]),
    ("lean_hover", #["path", "version", "line", "character"]),
    ("lean_goals_after", #["path", "version", "line", "character"]),
    ("lean_goals_prev", #["path", "version", "line", "character"]),
    ("lean_todo", #["path", "version", "start_line", "start_character", "end_line", "end_character"]),
    ("lean_run_with", #["path", "handle", "text"]),
    ("lean_run_with_linear", #["path", "handle", "text"]),
    ("lean_release", #["path", "handle"]),
    ("lean_update", #["path"]),
    ("lean_sync", #["path"]),
    ("lean_save", #["path"]),
    ("lean_close", #["path"])
  ]
  require "tools/list should expose init workspace plus curated Lean tools"
    (tools.size == schemaCases.size + 1)
  for (toolName, requiredFields) in schemaCases do
    let tool ← requireTool tools toolName
    let schema ← requireClosedInputSchema s!"{toolName} input schema" tool
    requireSchemaRequiredFields s!"{toolName} input schema" requiredFields schema
  let syncTool ← requireTool tools "lean_sync"
  let syncSchema ← requireClosedInputSchema "lean_sync input schema" syncTool
  let syncProperties ← requireObjVal "lean_sync input schema" "properties" syncSchema
  requireFieldPresent "lean_sync input schema" "include_diagnostics" syncProperties
  let saveTool ← requireTool tools "lean_save"
  let saveSchema ← requireClosedInputSchema "lean_save input schema" saveTool
  let saveProperties ← requireObjVal "lean_save input schema" "properties" saveSchema
  requireFieldAbsent "lean_save input schema" "include_diagnostics" saveProperties

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
  require "set unbound should not reuse runtime" (!setPlan.runtimeReused)

  discard <| expectWorkspacePlanError "verify unbound workspace" "not initialized" {} root .verify

  let readyState : Beam.Workspace.InitState := {
    root? := some root
    runtimeReady := true
  }
  let samePlan ← expectWorkspacePlan "set same workspace" readyState root .set
  require "same workspace should reuse runtime" samePlan.runtimeReused
  require "same workspace should not recreate runtime" (!samePlan.createRuntime)

  let setOtherErr ← expectWorkspacePlanError "set other workspace" "switch roots explicitly" readyState other .set
  require "set other workspace should report active root" (setOtherErr.activeRoot? == some root)

  let sameResetPlan ← expectWorkspacePlan "reset same workspace" readyState root .reset
  require "reset same workspace should create runtime" sameResetPlan.createRuntime
  require "reset same workspace should shut down current runtime" sameResetPlan.resetCurrent
  require "reset same workspace should target requested root" (sameResetPlan.root == root)
  require "reset same workspace should not reuse runtime" (!sameResetPlan.runtimeReused)
  require "reset same workspace should remember previous root" (sameResetPlan.previousRoot? == some root)

  let resetPlan ← expectWorkspacePlan "reset other workspace" readyState other .reset
  require "reset other workspace should create runtime" resetPlan.createRuntime
  require "reset other workspace should shut down current runtime" resetPlan.resetCurrent
  require "reset other workspace should target requested root" (resetPlan.root == other)
  require "reset other workspace should remember previous root" (resetPlan.previousRoot? == some root)
  let resetResult := Beam.Workspace.initResult resetPlan other
  require "reset result should report invalidated handles" resetResult.invalidatedHandles
  let resetJson := toJson resetResult
  requireJsonString "reset result json" "root" other.toString resetJson
  requireJsonString "reset result json" "active_root" other.toString resetJson
  requireJsonString "reset result json" "previous_root" root.toString resetJson
  requireJsonBool "reset result json" "invalidated_handles" true resetJson
  requireJsonBool "reset result json" "runtime_reused" false resetJson

  let setResultJson := toJson <| Beam.Workspace.initResult setPlan root
  requireJsonBool "set result json" "invalidated_handles" false setResultJson
  requireFieldAbsent "set result json" "previous_root" setResultJson

private def expectResponse (label : String) (value : Option Json × Bool) : IO Json := do
  match value with
  | (some json, _stop) => pure json
  | (none, _stop) => throw <| IO.userError s!"{label}: expected JSON-RPC response"

private def rpcRequest (id : Nat) (method : String) (params? : Option Json := none) : Json :=
  Json.mkObj <|
    [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson id),
      ("method", toJson method)
    ] ++
    match params? with
    | some params => [("params", params)]
    | none => []

private def rpcNotification (method : String) (params? : Option Json := none) : Json :=
  Json.mkObj <|
    [
      ("jsonrpc", toJson "2.0"),
      ("method", toJson method)
    ] ++
    match params? with
    | some params => [("params", params)]
    | none => []

private def toolCallParams (name : String) (arguments : Json := Json.mkObj []) : Json :=
  Json.mkObj [
    ("name", toJson name),
    ("arguments", arguments)
  ]

private def toolCallParamsWithProgress
    (name : String)
    (progressToken : Json)
    (arguments : Json := Json.mkObj []) : Json :=
  Json.mkObj [
    ("name", toJson name),
    ("arguments", arguments),
    ("_meta", Json.mkObj [
      ("progressToken", progressToken)
    ])
  ]

private def checkProgressProtocol : IO Unit := do
  let stringToken := Json.str "sync-token"
  let stringParams ← expectOk "decode string progressToken" <|
    Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" stringToken <|
        Json.mkObj [("path", toJson "Demo.lean")]
  require "string progressToken should decode" (stringParams.progressToken? == some stringToken)

  let numberToken := toJson (7 : Nat)
  let numberParams ← expectOk "decode numeric progressToken" <|
    Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" numberToken <|
        Json.mkObj [("path", toJson "Demo.lean")]
  require "numeric progressToken should decode" (numberParams.progressToken? == some numberToken)

  match Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" (toJson true) <|
        Json.mkObj [("path", toJson "Demo.lean")] with
  | .ok params =>
      throw <| IO.userError s!"invalid progressToken decoded unexpectedly: {(toJson params.progressToken?).compress}"
  | .error err =>
      require "invalid progressToken error should name progressToken" (err.contains "progressToken")

  let decimalToken := Json.num { mantissa := 15, exponent := 1 }
  match Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" decimalToken <|
        Json.mkObj [("path", toJson "Demo.lean")] with
  | .ok params =>
      throw <| IO.userError s!"decimal progressToken decoded unexpectedly: {(toJson params.progressToken?).compress}"
  | .error err =>
      require "decimal progressToken error should require integer" (err.contains "integer")

  let notification := Beam.Mcp.progressNotification stringToken 3 (some "syncing") (some 8)
  requireJsonString "progress notification" "method" "notifications/progress" notification
  let params ← requireObjVal "progress notification" "params" notification
  requireJsonString "progress notification params" "progressToken" "sync-token" params
  requireJsonInt "progress notification params" "progress" 3 params
  requireJsonInt "progress notification params" "total" 8 params
  requireJsonString "progress notification params" "message" "syncing" params

private def handleRpcRequest
    (state : IO.Ref Beam.Mcp.Server.ProtocolState)
    (opts : Beam.Mcp.Server.Options)
    (stdin : IO.FS.Stream)
    (label : String)
    (id : Nat)
    (method : String)
    (params? : Option Json := none) : IO Json := do
  expectResponse label =<<
    Beam.Mcp.Server.handleJson state opts stdin (rpcRequest id method params?)

private def handleRpcRequestWithNotifications
    (state : IO.Ref Beam.Mcp.Server.ProtocolState)
    (opts : Beam.Mcp.Server.Options)
    (stdin : IO.FS.Stream)
    (notifications : Beam.Mcp.Server.NotificationSink)
    (label : String)
    (id : Nat)
    (method : String)
    (params? : Option Json := none) : IO Json := do
  expectResponse label =<<
    Beam.Mcp.Server.handleJson state opts stdin (rpcRequest id method params?) notifications

private def expectRpcErrorCode (label : String) (expected : Int) (resp : Json) : IO Json := do
  let err ← requireObjVal label "error" resp
  requireJsonInt label "code" expected err
  pure err

private def expectToolErrorCode (label expectedCode : String) (resp : Json) : IO Json := do
  let result ← requireObjVal s!"{label} response" "result" resp
  requireJsonBool s!"{label} result" "isError" true result
  let structured ← requireObjVal s!"{label} result" "structuredContent" result
  requireJsonString s!"{label} structured error" "code" expectedCode structured
  pure structured

private def checkServerBasics : IO Unit := do
  let root ← IO.currentDir
  let state ← Beam.Mcp.Server.ProtocolState.create (some root)
  let stdin ← IO.getStdin
  let opts : Beam.Mcp.Server.Options := {}

  let preInitResp ← handleRpcRequest state opts stdin "pre-initialize tools/list rejection" 0 "tools/list"
  discard <| expectRpcErrorCode "pre-initialize tools/list response" (-32600) preInitResp

  let initResp ← handleRpcRequest state opts stdin "initialize" 1 "initialize" <| some <|
    Json.mkObj [
        ("protocolVersion", toJson Beam.Mcp.protocolVersion),
        ("capabilities", Json.mkObj [])
    ]
  let initResult ← requireObjVal "initialize response" "result" initResp
  requireJsonString "initialize result" "protocolVersion" Beam.Mcp.protocolVersion initResult
  let capabilities ← requireObjVal "initialize result" "capabilities" initResult
  discard <| requireObjVal "initialize capabilities" "logging" capabilities
  let toolsCapability ← requireObjVal "initialize capabilities" "tools" capabilities
  requireJsonBool "initialize tools capability" "listChanged" false toolsCapability

  let setLogLevelResp ← handleRpcRequest state opts stdin "set log level" 12 "logging/setLevel" <| some <|
    Json.mkObj [
      ("level", toJson "warning")
    ]
  discard <| requireObjVal "set log level response" "result" setLogLevelResp
  require "set log level should update protocol state" ((← state.get).logLevel == .warning)

  let badLogLevelResp ← handleRpcRequest state opts stdin "bad log level" 13 "logging/setLevel" <| some <|
    Json.mkObj [
      ("level", toJson "verbose")
    ]
  discard <| expectRpcErrorCode "bad log level response" (-32602) badLogLevelResp

  let preReadyResp ← handleRpcRequest state opts stdin "pre-ready tools/list rejection" 11 "tools/list"
  discard <| expectRpcErrorCode "pre-ready tools/list response" (-32600) preReadyResp

  let initializedResp ←
    Beam.Mcp.Server.handleJson state opts stdin (rpcNotification "notifications/initialized")
  match initializedResp with
  | (none, false) => pure ()
  | (some json, stop) =>
      throw <| IO.userError s!"initialized notification should not produce a response/stop: {json.compress}, {stop}"
  | (none, true) =>
      throw <| IO.userError "initialized notification should not stop the server"

  let listResp ← handleRpcRequest state opts stdin "tools/list" 2 "tools/list"
  let listResult ← requireObjVal "tools/list response" "result" listResp
  discard <| requireObjVal "tools/list response" "tools" listResult

  let rawToolResp ← handleRpcRequest state opts stdin "raw tool rejection" 3 "tools/call" <|
    some <| toolCallParams RunAt.method
  discard <| expectRpcErrorCode "raw tool response" (-32602) rawToolResp

  let badInitResp ← handleRpcRequest state opts stdin "bad init workspace input" 31 "tools/call" <|
    some <| toolCallParams "lean_init_workspace"
  discard <| expectToolErrorCode "bad init workspace" "invalidInput" badInitResp

  let relativeInitResp ← handleRpcRequest state opts stdin "relative init workspace input" 32 "tools/call" <|
    some <| toolCallParams "lean_init_workspace" <|
      Json.mkObj [
          ("root", toJson "relative/project")
      ]
  let relativeInitStructured ← expectToolErrorCode "relative init workspace" "invalidInput" relativeInitResp
  let relativeMessage ← IO.ofExcept <| relativeInitStructured.getObjValAs? String "message"
  require "relative init workspace error should require absolute path" (relativeMessage.contains "absolute")

  let badArgsResp ← handleRpcRequest state opts stdin "bad args rejection" 4 "tools/call" <|
    some <| toolCallParams "lean_run_at" <|
      Json.mkObj [
          ("path", toJson "Demo.lean"),
          ("line", toJson (0 : Nat)),
          ("character", toJson (0 : Nat))
      ]
  discard <| expectToolErrorCode "bad args" "invalidInput" badArgsResp

private def diagnosticLogNotifications (notifications : Array Json) : Array Json :=
  notifications.filter fun notification =>
    (notification.getObjValAs? String "method").toOption == some "notifications/message" &&
      ((notification.getObjVal? "params").toOption.bind fun params =>
        (params.getObjValAs? String "logger").toOption) == some "lean.diagnostic"

private def requireDiagnosticLog
    (notifications : Array Json)
    (level severity path : String) : IO Json := do
  let logs := diagnosticLogNotifications notifications
  let some notification := logs.find? fun notification =>
      match notification.getObjVal? "params" with
      | .error _ => false
      | .ok params =>
          (params.getObjValAs? String "level").toOption == some level &&
          match params.getObjVal? "data" with
          | .error _ => false
          | .ok data =>
              (data.getObjValAs? String "severity").toOption == some severity &&
                (data.getObjValAs? String "path").toOption == some path
    | throw <| IO.userError
        s!"expected {level}/{severity} diagnostic log for {path}, got {(toJson notifications).compress}"
  pure notification

private def expectNoDiagnosticLogs (label : String) (notifications : Array Json) : IO Unit := do
  let logs := diagnosticLogNotifications notifications
  unless logs.isEmpty do
    throw <| IO.userError s!"expected no {label} diagnostic logs, got {(toJson logs).compress}"

private def mcpOptionsWithPlugin : IO Beam.Mcp.Server.Options := do
  pure {
    leanCmd? := some "lean"
    leanPlugin? := some (← RunAtTest.TestHarness.pluginPath).toString
  }

private def initMcpSession
    (state : IO.Ref Beam.Mcp.Server.ProtocolState)
    (opts : Beam.Mcp.Server.Options)
    (stdin : IO.FS.Stream)
    (notifications : Beam.Mcp.Server.NotificationSink) : IO Unit := do
  let _ ← handleRpcRequestWithNotifications state opts stdin notifications "initialize" 1 "initialize" <| some <|
    Json.mkObj [
      ("protocolVersion", toJson Beam.Mcp.protocolVersion),
      ("capabilities", Json.mkObj [])
    ]
  let initializedResp ←
    Beam.Mcp.Server.handleJson state opts stdin (rpcNotification "notifications/initialized") notifications
  match initializedResp with
  | (none, false) => pure ()
  | (some json, stop) =>
      throw <| IO.userError s!"initialized notification should not produce a response/stop: {json.compress}, {stop}"
  | (none, true) =>
      throw <| IO.userError "initialized notification should not stop the server"

private def callLeanSync
    (state : IO.Ref Beam.Mcp.Server.ProtocolState)
    (opts : Beam.Mcp.Server.Options)
    (stdin : IO.FS.Stream)
    (notifications : Beam.Mcp.Server.NotificationSink)
    (id : Nat)
    (path : String)
    (fullDiagnostics : Bool := true)
    (includeDiagnostics : Bool := false) : IO Json := do
  let arguments := Json.mkObj <|
    [
      ("path", toJson path),
      ("full_diagnostics", toJson fullDiagnostics)
    ] ++
    if includeDiagnostics then
      [("include_diagnostics", toJson true)]
    else
      []
  handleRpcRequestWithNotifications state opts stdin notifications s!"lean_sync {path}" id "tools/call" <|
    some <| toolCallParams "lean_sync" arguments

private def shutdownMcpRuntime (state : IO.Ref Beam.Mcp.Server.ProtocolState) : IO Unit := do
  let current ← state.get
  match current.runtime? with
  | none => pure ()
  | some runtime =>
      discard <| runtime.dispatchRequest { op := .shutdown }

private def checkDiagnosticLogForwarding : IO Unit := do
  let root ← mkTempProjectRoot "lean-beam-mcp-diagnostic-log"
  let state ← Beam.Mcp.Server.ProtocolState.create (some root)
  try
    copySaveProjectFixture root
    let stdin ← IO.getStdin
    let opts ← mcpOptionsWithPlugin
    let notificationsRef ← IO.mkRef #[]
    let notifications : Beam.Mcp.Server.NotificationSink := {
      send := fun notification =>
        notificationsRef.modify fun seen => seen.push notification
    }
    initMcpSession state opts stdin notifications

    writeSaveWarningFile root "-- mcp diagnostic log"
    let syncResp ← callLeanSync state opts stdin notifications 2 "SaveSmoke/B.lean"
      (includeDiagnostics := true)
    let syncResult ← requireObjVal "lean_sync response" "result" syncResp
    requireJsonBool "lean_sync result" "isError" false syncResult
    let syncStructured ← requireObjVal "lean_sync result" "structuredContent" syncResult
    let replyDiagnosticsJson ← requireObjVal "lean_sync structured result" "diagnostics" syncStructured
    let replyDiagnostics ←
      match replyDiagnosticsJson with
      | Json.arr diagnostics => pure diagnostics
      | other =>
          throw <| IO.userError
            s!"expected lean_sync include_diagnostics diagnostics array, got {other.compress}"
    if replyDiagnostics.isEmpty then
      throw <| IO.userError
        s!"expected lean_sync include_diagnostics to replay diagnostics, got {syncStructured.compress}"
    unless replyDiagnostics.any (fun diagnostic =>
        (diagnostic.getObjValAs? String "path").toOption == some "SaveSmoke/B.lean" &&
        (diagnostic.getObjValAs? String "severity").toOption == some "warning") do
      throw <| IO.userError
        s!"expected lean_sync include_diagnostics warning diagnostic, got {syncStructured.compress}"
    let warningLog ← requireDiagnosticLog (← notificationsRef.get) "warning" "warning" "SaveSmoke/B.lean"
    let params ← requireObjVal "warning log notification" "params" warningLog
    let data ← requireObjVal "warning log params" "data" params
    discard <| requireObjVal "warning log data" "range" data
    discard <| requireObjVal "warning log data" "uri" data
    discard <| requireObjVal "warning log data" "version" data
    requireJsonBool "warning log data" "completionBlocking" false data
    requireFieldAbsent "warning log data" "saveBlocking" data
    let message ← IO.ofExcept <| data.getObjValAs? String "message"
    require "warning log should preserve diagnostic message" (!message.isEmpty)

    let _ ← handleRpcRequestWithNotifications state opts stdin notifications "set error log level" 3
      "logging/setLevel" <| some <| Json.mkObj [
        ("level", toJson "error")
      ]
    notificationsRef.set #[]
    writeSaveWarningFile root "-- mcp warning suppressed"
    let suppressedResp ← callLeanSync state opts stdin notifications 4 "SaveSmoke/B.lean"
    let suppressedResult ← requireObjVal "suppressed lean_sync response" "result" suppressedResp
    requireJsonBool "suppressed lean_sync result" "isError" false suppressedResult
    let suppressedStructured ← requireObjVal "suppressed lean_sync result" "structuredContent" suppressedResult
    requireFieldAbsent "suppressed lean_sync result" "diagnostics" suppressedStructured
    expectNoDiagnosticLogs "warning-only after error log level" (← notificationsRef.get)

    notificationsRef.set #[]
    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := \"broken\"\n"
    let errorResp ← callLeanSync state opts stdin notifications 5 "SaveSmoke/B.lean"
    let errorResult ← requireObjVal "error lean_sync response" "result" errorResp
    requireJsonBool "error lean_sync result" "isError" false errorResult
    let errorLog ← requireDiagnosticLog (← notificationsRef.get) "error" "error" "SaveSmoke/B.lean"
    let errorParams ← requireObjVal "error log notification" "params" errorLog
    let errorData ← requireObjVal "error log params" "data" errorParams
    requireJsonBool "error log data" "completionBlocking" false errorData
    requireFieldAbsent "error log data" "saveBlocking" errorData
  finally
    shutdownMcpRuntime state
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

def main : IO Unit := do
  checkJsonHelpers
  checkIncoming
  checkToolsListShape
  checkRootsProtocol
  checkProgressProtocol
  checkRuntimeSetupErrors
  checkWorkspaceInitPolicy
  checkServerBasics
  checkDiagnosticLogForwarding

end RunAtTest.Broker.McpProtocolTest

def main := RunAtTest.Broker.McpProtocolTest.main
