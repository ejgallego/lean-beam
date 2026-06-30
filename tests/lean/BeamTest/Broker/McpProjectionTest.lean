/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Projection
import BeamTest.Broker.JsonAssert

open Lean
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpProjectionTest

private def expectToolOk (label : String) (result : Except Beam.Mcp.ToolError Json) : IO Json := do
  match result with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label}: {err.code}: {err.message}"

private def expectToolError (label expectedCode : String) (result : Except Beam.Mcp.ToolError Json) :
    IO Beam.Mcp.ToolError := do
  match result with
  | .ok json =>
      throw <| IO.userError s!"{label}: expected error {expectedCode}, got {json.compress}"
  | .error err =>
      if err.code != expectedCode then
        throw <| IO.userError s!"{label}: expected error {expectedCode}, got {err.code}: {err.message}"
      pure err

private def sampleBrokerHandle : Beam.Broker.Handle := {
  backend := .lean
  epoch := 3
  session := "session"
  raw := toJson ({ value := "raw-handle" } : Beam.LSP.RunAt.Handle)
}

private def expectedLeanOperationSurface : Array Beam.Lean.Operation := #[
  .runAt,
  .runAtHandle,
  .hover,
  .goalsAfter,
  .goalsPrev,
  .todo,
  .runWith,
  .runWithLinear,
  .release,
  .update,
  .sync,
  .refresh,
  .save,
  .closeSave,
  .close
]

private def requireSameOperationSurface
    (label : String)
    (actual expected : Array Beam.Lean.Operation) : IO Unit := do
  require s!"{label}: expected size {expected.size}, got {actual.size}"
    (actual.size == expected.size)
  for op in expected do
    require s!"{label}: missing operation {repr op}" (actual.contains op)
  for op in actual do
    require s!"{label}: unexpected operation {repr op}" (expected.contains op)

private def checkToolNames : IO Unit := do
  let decodedBeamVersion ← expectOk "decode beam_version" <|
    fromJson? (α := Beam.Mcp.ToolName) (Json.str "beam_version")
  require "decode beam_version: wrong tool" (decodedBeamVersion == .beamVersion)

  let decodedBeamStats ← expectOk "decode beam_stats" <|
    fromJson? (α := Beam.Mcp.ToolName) (Json.str "beam_stats")
  require "decode beam_stats: wrong tool" (decodedBeamStats == .beamStats)

  let initWorkspace ← expectOk "decode lean_init_workspace" <|
    fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_init_workspace")
  require "decode lean_init_workspace: wrong tool" (initWorkspace == .leanInitWorkspace)

  let decoded ← expectOk "decode lean_run_at" <| fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_run_at")
  require "decode lean_run_at: wrong tool" (decoded == .leanRunAt)

  let hover ← expectOk "decode lean_hover" <| fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_hover")
  require "decode lean_hover: wrong tool" (hover == .leanHover)

  let todo ← expectOk "decode lean_todo" <| fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_todo")
  require "decode lean_todo: wrong tool" (todo == .leanTodo)

  let refresh ← expectOk "decode lean_refresh" <| fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_refresh")
  require "decode lean_refresh: wrong tool" (refresh == .leanRefresh)

  let closeSave ← expectOk "decode lean_close_save" <|
    fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_close_save")
  require "decode lean_close_save: wrong tool" (closeSave == .leanCloseSave)

  match fromJson? (α := Beam.Mcp.ToolName) (Json.str Beam.LSP.RunAt.method) with
  | .ok tool =>
      throw <| IO.userError s!"raw LSP method decoded as MCP tool: {repr tool}"
  | .error _ =>
      pure ()

  match fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_request_at") with
  | .ok tool =>
      throw <| IO.userError s!"raw request escape hatch decoded as MCP tool: {repr tool}"
  | .error _ =>
      pure ()

private def checkToolDescriptors : IO Unit := do
  requireSameOperationSurface "curated Lean operation surface"
    Beam.Lean.Operation.all
    expectedLeanOperationSurface
  require "tool descriptor count tracks tool name count"
    (Beam.Mcp.toolDescriptors.size == Beam.Mcp.toolNames.size)
  let mut seenToolKeys : Array String := #[]
  for tool in Beam.Mcp.toolNames do
    require s!"duplicate MCP tool name {tool.key}" (!seenToolKeys.contains tool.key)
    seenToolKeys := seenToolKeys.push tool.key
    let decoded ← expectOk s!"decode generated tool key {tool.key}" <|
      fromJson? (α := Beam.Mcp.ToolName) (Json.str tool.key)
    require s!"generated tool key should decode back to {repr tool}" (decoded == tool)
  require "Lean operation tool names track shared operation surface"
    (Beam.Mcp.leanOperationToolNames.size == Beam.Lean.Operation.all.size)
  require "tool names are server tools, init workspace, plus shared Lean operations"
    (Beam.Mcp.toolNames.size == Beam.Lean.Operation.all.size + 3)
  for op in Beam.Lean.Operation.all do
    let projectedTool := Beam.Mcp.ToolName.ofLeanOperation op
    require s!"Lean operation {repr op} should round-trip through MCP projection"
      (projectedTool.leanOperation? == some op)
    require s!"Lean operation {repr op} should derive MCP key from operation key"
      (projectedTool.key == "lean_" ++ op.key)
    let matchingTools := Beam.Mcp.leanOperationToolNames.filter (fun tool =>
      tool.kind == .leanOperation op)
    require s!"Lean operation {repr op} should have exactly one MCP tool"
      (matchingTools.size == 1)
  require "init workspace descriptor is exposed as setup tool"
    (Beam.Mcp.toolDescriptors.any (fun desc =>
      desc.name == .leanInitWorkspace && desc.kind == .workspaceInit))
  require "beam version descriptor is exposed as server info tool"
    (Beam.Mcp.toolDescriptors.any (fun desc =>
      desc.name == .beamVersion && desc.kind == .serverInfo))
  require "beam stats descriptor is exposed as server debug tool"
    (Beam.Mcp.toolDescriptors.any (fun desc =>
      desc.name == .beamStats && desc.kind == .serverDebug))
  let some versionDesc := Beam.Mcp.toolDescriptors.find? (·.name == .beamVersion)
    | throw <| IO.userError "beam version descriptor is missing"
  let versionSchemaProperties ← requireObjVal "beam version schema" "properties" versionDesc.inputSchema
  require "beam version schema should have no input properties" (versionSchemaProperties == Json.mkObj [])
  let some statsDesc := Beam.Mcp.toolDescriptors.find? (·.name == .beamStats)
    | throw <| IO.userError "beam stats descriptor is missing"
  let statsSchemaProperties ← requireObjVal "beam stats schema" "properties" statsDesc.inputSchema
  require "beam stats schema should have no input properties" (statsSchemaProperties == Json.mkObj [])
  let some initDesc := Beam.Mcp.toolDescriptors.find? (·.name == .leanInitWorkspace)
    | throw <| IO.userError "init workspace descriptor is missing"
  let schemaProperties ← requireObjVal "init workspace schema" "properties" initDesc.inputSchema
  discard <| requireObjVal "init workspace schema properties" "root" schemaProperties
  discard <| requireObjVal "init workspace schema properties" "mode" schemaProperties
  require "hover descriptor is exposed"
    (Beam.Mcp.toolDescriptors.any (fun desc =>
      desc.name == .leanHover && desc.kind == .leanOperation .hover))
  require "goals-after descriptor is exposed"
    (Beam.Mcp.toolDescriptors.any (fun desc =>
      desc.name == .leanGoalsAfter && desc.kind == .leanOperation .goalsAfter))
  require "todo descriptor is exposed"
    (Beam.Mcp.toolDescriptors.any (fun desc =>
      desc.name == .leanTodo && desc.kind == .leanOperation .todo))

private def checkBrokerRequestAdapters : IO Unit := do
  let root := "/repo"
  match Beam.Mcp.ToolName.beamVersion.toBrokerRequest root (Json.mkObj []) with
  | .ok req =>
      throw <| IO.userError s!"beam version produced broker request unexpectedly: {repr req.op}"
  | .error err =>
      require "beam version broker adapter error names server identity behavior" (err.contains "server identity")

  let statsReq ← expectOk "beam stats tool request" <|
    Beam.Mcp.ToolName.beamStats.toBrokerRequest root (Json.mkObj [])
  require "beam stats op" (statsReq.op == .stats)
  require "beam stats root" (statsReq.root? == some root)

  match Beam.Mcp.ToolName.beamStats.toBrokerRequest root (Json.mkObj [("path", toJson "Demo.lean")]) with
  | .ok req =>
      throw <| IO.userError s!"beam stats accepted input fields unexpectedly: {repr req.op}"
  | .error err =>
      require "beam stats broker adapter rejects input fields" (err.contains "accepts no input fields")

  match Beam.Mcp.ToolName.leanInitWorkspace.toBrokerRequest root (toJson ({ root := root } : Beam.Mcp.InitWorkspaceInput)) with
  | .ok req =>
      throw <| IO.userError s!"init workspace produced broker request unexpectedly: {repr req.op}"
  | .error err =>
      require "init workspace broker adapter error names setup behavior" (err.contains "does not map")

  let resetInitJson := toJson ({ root := root, mode? := some .reset } : Beam.Mcp.InitWorkspaceInput)
  requireJsonString "init workspace mode json" "mode" "reset" resetInitJson

  let runAtInput : Beam.Mcp.RunAtInput := {
    path := "Demo.lean"
    version := 12
    line := 4
    character := 2
    text := "exact h"
  }
  let runAtReq ← expectOk "runAt tool request" <|
    Beam.Mcp.ToolName.leanRunAt.toBrokerRequest root (toJson runAtInput)
  require "runAt op" (runAtReq.op == .runAt)
  require "runAt backend" (runAtReq.backend == .lean)
  require "runAt root" (runAtReq.root? == some root)
  require "runAt path" (runAtReq.path? == some "Demo.lean")
  require "runAt version" (runAtReq.version? == some 12)
  require "runAt line" (runAtReq.line? == some 4)
  require "runAt character" (runAtReq.character? == some 2)
  require "runAt text" (runAtReq.text? == some "exact h")
  require "runAt does not store by default" runAtReq.storeHandle?.isNone
  require "runAt hides raw LSP method" runAtReq.method?.isNone
  require "runAt hides raw LSP params" runAtReq.params?.isNone
  requireFieldAbsent "runAt input json" "root" (toJson runAtInput)

  let runAtHandleReq ← expectOk "runAt handle tool request" <|
    Beam.Mcp.ToolName.leanRunAtHandle.toBrokerRequest root (toJson runAtInput)
  require "runAt handle stores state" (runAtHandleReq.storeHandle? == some true)

  let positionInput : Beam.Mcp.PositionInput := {
    path := "Demo.lean"
    version := 13
    line := 7
    character := 3
  }
  let hoverReq ← expectOk "hover tool request" <|
    Beam.Mcp.ToolName.leanHover.toBrokerRequest root (toJson positionInput)
  require "hover uses requestAt broker op" (hoverReq.op == .requestAt)
  require "hover version" (hoverReq.version? == some 13)
  require "hover injects hover method" (hoverReq.method? == some "textDocument/hover")
  require "hover hides raw params" hoverReq.params?.isNone

  let goalsAfterReq ← expectOk "goals-after tool request" <|
    Beam.Mcp.ToolName.leanGoalsAfter.toBrokerRequest root (toJson positionInput)
  require "goals-after op" (goalsAfterReq.op == .goals)
  require "goals-after mode" (goalsAfterReq.mode? == some .after)

  let goalsPrevReq ← expectOk "goals-prev tool request" <|
    Beam.Mcp.ToolName.leanGoalsPrev.toBrokerRequest root (toJson positionInput)
  require "goals-prev op" (goalsPrevReq.op == .goals)
  require "goals-prev mode" (goalsPrevReq.mode? == some .prev)

  let todoInput : Beam.Mcp.TodoInput := {
    path := "Demo.lean"
    version := 14
    startLine := 1
    startCharacter := 0
    endLine := 8
    endCharacter := 3
    kinds? := some #[.sorry, .incompleteProof]
    suggest? := some .basic
  }
  let todoReq ← expectOk "todo tool request" <|
    Beam.Mcp.ToolName.leanTodo.toBrokerRequest root (toJson todoInput)
  require "todo op" (todoReq.op == .todo)
  require "todo backend" (todoReq.backend == .lean)
  require "todo version" (todoReq.version? == some 14)
  require "todo start line" (todoReq.line? == some 1)
  require "todo start character" (todoReq.character? == some 0)
  require "todo end line" (todoReq.endLine? == some 8)
  require "todo end character" (todoReq.endCharacter? == some 3)
  require "todo kinds" (todoReq.kinds? == some #[.sorry, .incompleteProof])
  require "todo suggest" (todoReq.suggest? == some .basic)
  require "todo hides raw LSP method" todoReq.method?.isNone
  require "todo hides raw LSP params" todoReq.params?.isNone
  let todoJson := toJson todoInput
  requireJsonString "todo input json" "path" "Demo.lean" todoJson
  requireFieldAbsent "todo input json" "startLine" todoJson
  requireFieldAbsent "todo input json" "root" todoJson

  let runWithInput : Beam.Mcp.RunWithInput := {
    path := "Demo.lean"
    handle := sampleBrokerHandle
    text := "simp"
  }
  let runWithReq ← expectOk "runWith tool request" <|
    Beam.Mcp.ToolName.leanRunWithLinear.toBrokerRequest root (toJson runWithInput)
  require "runWith op" (runWithReq.op == .runWith)
  require "runWith stores successor handle" (runWithReq.storeHandle? == some true)
  require "runWith linear flag" (runWithReq.linear? == some true)
  require "runWith handle present" runWithReq.handle?.isSome
  require "runWith hides raw LSP method" runWithReq.method?.isNone
  require "runWith hides raw LSP params" runWithReq.params?.isNone
  requireFieldAbsent "runWith input json" "root" (toJson runWithInput)

  let pathInput : Beam.Mcp.PathInput := { path := "Demo.lean" }
  let updateReq ← expectOk "update tool request" <|
    Beam.Mcp.ToolName.leanUpdate.toBrokerRequest root (toJson pathInput)
  require "update op" (updateReq.op == .updateFile)
  let closeReq ← expectOk "close tool request" <|
    Beam.Mcp.ToolName.leanClose.toBrokerRequest root (toJson pathInput)
  require "close op" (closeReq.op == .close)

  let syncInput : Beam.Mcp.SyncInput := {
    path := "Demo.lean",
    fullDiagnostics? := some true,
    includeDiagnostics? := some true
  }
  let syncReq ← expectOk "sync tool request" <|
    Beam.Mcp.ToolName.leanSync.toBrokerRequest root (toJson syncInput)
  require "sync op" (syncReq.op == .syncFile)
  require "sync full diagnostics" (syncReq.fullDiagnostics? == some true)
  require "sync include diagnostics" (syncReq.includeDiagnostics? == some true)
  let refreshReq ← expectOk "refresh tool request" <|
    Beam.Mcp.ToolName.leanRefresh.toBrokerRequest root (toJson syncInput)
  require "refresh op" (refreshReq.op == .refreshFile)
  require "refresh full diagnostics" (refreshReq.fullDiagnostics? == some true)
  require "refresh include diagnostics" (refreshReq.includeDiagnostics? == some true)
  let saveReq ← expectOk "save tool request" <|
    Beam.Mcp.ToolName.leanSave.toBrokerRequest root (toJson syncInput)
  require "save op" (saveReq.op == .saveOlean)
  require "save full diagnostics" (saveReq.fullDiagnostics? == some true)
  require "save should not request reply diagnostics" saveReq.includeDiagnostics?.isNone
  let closeSaveReq ← expectOk "close-save tool request" <|
    Beam.Mcp.ToolName.leanCloseSave.toBrokerRequest root (toJson syncInput)
  require "close-save op" (closeSaveReq.op == .close)
  require "close-save requests artifact save" (closeSaveReq.saveArtifacts? == some true)
  require "close-save full diagnostics" (closeSaveReq.fullDiagnostics? == some true)
  require "close-save should not request reply diagnostics" closeSaveReq.includeDiagnostics?.isNone
  let syncJson := toJson syncInput
  requireJsonBool "sync input json" "full_diagnostics" true syncJson
  requireJsonBool "sync input json" "include_diagnostics" true syncJson
  requireFieldAbsent "sync input json" "fullDiagnostics" syncJson
  requireFieldAbsent "sync input json" "includeDiagnostics" syncJson
  requireFieldAbsent "sync input json" "root" syncJson
  let decodedSync ← expectOk "decode sync input" <| fromJson? (α := Beam.Mcp.SyncInput) syncJson
  require "decoded sync full diagnostics" (decodedSync.fullDiagnostics? == some true)
  require "decoded sync include diagnostics" (decodedSync.includeDiagnostics? == some true)

private def checkRunAtNormalization : IO Unit := do
  let semanticFailure := Json.mkObj [("success", toJson false)]
  let normalizedFailure ← expectToolOk "normalize semantic failure" <|
    Beam.Mcp.normalizeBrokerResponse .leanRunAt {
      ok := true
      result? := some semanticFailure
    }
  requireJsonBool "semantic failure result" "success" false normalizedFailure
  requireJsonNull "semantic failure result" "next_handle" normalizedFailure
  requireJsonNull "semantic failure result" "proof_state" normalizedFailure
  requireFieldAbsent "semantic failure result" "ok" normalizedFailure
  requireFieldAbsent "semantic failure result" "handle" normalizedFailure
  requireFieldAbsent "semantic failure result" "proofState" normalizedFailure

  let successWithHandle := Json.mkObj [
    ("success", toJson true),
    ("messages", toJson (#[] : Array Beam.LSP.RunAt.Message)),
    ("traces", toJson (#[] : Array String)),
    ("handle", toJson sampleBrokerHandle)
  ]
  let normalizedHandle ← expectToolOk "normalize handle result" <|
    Beam.Mcp.normalizeBrokerResponse .leanRunAtHandle {
      ok := true
      result? := some successWithHandle
      fileProgress? := some { updates := 2, done := true }
      clientRequestId? := some "req-1"
    }
  let nextHandle ← requireObjVal "handle result" "next_handle" normalizedHandle
  requireJsonString "next handle" "session" "session" nextHandle
  let rawHandle ← requireObjVal "next handle" "raw" nextHandle
  requireJsonString "next handle raw" "value" "raw-handle" rawHandle
  let progress ← requireObjVal "handle result" "file_progress" normalizedHandle
  requireJsonBool "handle result progress" "done" true progress
  requireJsonString "handle result request id" "client_request_id" "req-1" normalizedHandle
  requireFieldAbsent "handle result" "handle" normalizedHandle

private def checkTransportErrorNormalization : IO Unit := do
  let err ← expectToolError "normalize transport error" "invalidParams" <|
    Beam.Mcp.normalizeBrokerResponse .leanRunAt {
      ok := false
      error? := some { code := "invalidParams", message := "bad position" }
    }
  require "transport error message" (err.message == "bad position")

private def checkTodoNormalization : IO Unit := do
  let rawTodo := Json.mkObj [
    ("version", toJson (1 : Nat)),
    ("range", toJson ({ start := { line := 0, character := 0 }, «end» := { line := 2, character := 0 } } : Lean.Lsp.Range)),
    ("items", Json.arr #[
      Json.mkObj [
        ("kind", toJson Beam.LSP.Todo.TodoKind.incompleteProof),
        ("range", toJson ({ start := { line := 1, character := 2 }, «end» := { line := 1, character := 7 } } : Lean.Lsp.Range)),
        ("runAtPosition", toJson ({ line := 1, character := 7 } : Lean.Lsp.Position)),
        ("runAtText", toJson ("exact ?_" : String)),
        ("proofState", toJson ({ goals := #[] } : Beam.LSP.Lib.ProofState))
      ],
      Json.mkObj [
        ("kind", toJson Beam.LSP.Todo.TodoKind.codeAction),
        ("range", toJson ({ start := { line := 1, character := 10 }, «end» := { line := 1, character := 11 } } : Lean.Lsp.Range)),
        ("runAtPosition", toJson ({ line := 1, character := 10 } : Lean.Lsp.Position)),
        ("codeAction", Json.mkObj [
          ("title", toJson ("Replace fixture hole with zero" : String)),
          ("kind", toJson ("quickfix" : String))
        ])
      ]
    ])
  ]
  let normalized ← expectToolOk "normalize todo result" <|
    Beam.Mcp.normalizeBrokerResponse .leanTodo {
      ok := true
      result? := some rawTodo
    }
  let items ← requireObjVal "todo result" "items" normalized
  let item ←
    match items with
    | Json.arr items =>
        match items[0]? with
        | some item => pure item
        | none => throw <| IO.userError "todo result: expected first item"
    | _ => throw <| IO.userError s!"todo result: expected items array, got {items.compress}"
  discard <| requireObjVal "todo item" "run_at_position" item
  requireJsonString "todo item" "run_at_text" "exact ?_" item
  discard <| requireObjVal "todo item" "proof_state" item
  requireFieldAbsent "todo item" "runAtPosition" item
  requireFieldAbsent "todo item" "runAtText" item
  requireFieldAbsent "todo item" "proofState" item
  let codeActionItem ←
    match items with
    | Json.arr items =>
        match items[1]? with
        | some item => pure item
        | none => throw <| IO.userError "todo result: expected second item"
    | _ => throw <| IO.userError s!"todo result: expected items array, got {items.compress}"
  discard <| requireObjVal "todo code action item" "code_action" codeActionItem
  requireFieldAbsent "todo code action item" "codeAction" codeActionItem

private def checkInvalidEnvelopeRejection : IO Unit := do
  discard <| expectToolError "missing error envelope" "invalidEnvelope" <|
    Beam.Mcp.normalizeBrokerResponse .leanRunAt { ok := false }

  discard <| expectToolError "ok envelope with error" "invalidEnvelope" <|
    Beam.Mcp.normalizeBrokerResponse .leanRunAt {
      ok := true
      error? := some { code := "internalError", message := "bad envelope" }
    }

def main : IO Unit := do
  checkToolNames
  checkToolDescriptors
  checkBrokerRequestAdapters
  checkRunAtNormalization
  checkTransportErrorNormalization
  checkTodoNormalization
  checkInvalidEnvelopeRejection

end BeamTest.Broker.McpProjectionTest

def main := BeamTest.Broker.McpProjectionTest.main
