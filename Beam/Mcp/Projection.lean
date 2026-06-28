/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation
import Beam.JsonSchema
import Beam.Mcp.Diagnostics
import Beam.Mcp.Json
import Beam.Workspace
import RunAt.Protocol

open Lean

namespace Beam.Mcp

/--
Agent-facing MCP tool names supported by the Lean projection.

This is intentionally smaller than the broker and LSP surfaces. In particular, raw LSP method names
such as `$/lean/runAt` are not accepted here.
-/
inductive ToolName where
  | leanInitWorkspace
  | leanOperation (operation : Beam.Lean.Operation)
  deriving BEq, Repr

/-- MCP tool categories after projecting the shared Beam operation surface. -/
inductive ToolKind where
  | workspaceInit
  | leanOperation (operation : Beam.Lean.Operation)
  deriving BEq, Repr

def ToolName.ofLeanOperation (operation : Beam.Lean.Operation) : ToolName :=
  .leanOperation operation

def ToolName.leanRunAt : ToolName := .leanOperation .runAt
def ToolName.leanRunAtHandle : ToolName := .leanOperation .runAtHandle
def ToolName.leanHover : ToolName := .leanOperation .hover
def ToolName.leanGoalsAfter : ToolName := .leanOperation .goalsAfter
def ToolName.leanGoalsPrev : ToolName := .leanOperation .goalsPrev
def ToolName.leanTodo : ToolName := .leanOperation .todo
def ToolName.leanRunWith : ToolName := .leanOperation .runWith
def ToolName.leanRunWithLinear : ToolName := .leanOperation .runWithLinear
def ToolName.leanRelease : ToolName := .leanOperation .release
def ToolName.leanSync : ToolName := .leanOperation .sync
def ToolName.leanDeps : ToolName := .leanOperation .deps
def ToolName.leanSave : ToolName := .leanOperation .save
def ToolName.leanClose : ToolName := .leanOperation .close

def ToolName.leanOperation? : ToolName → Option Beam.Lean.Operation
  | .leanInitWorkspace => none
  | .leanOperation operation => some operation

private def leanOperationToolKey (operation : Beam.Lean.Operation) : String :=
  "lean_" ++ operation.key

def ToolName.leanOperationTools : Array ToolName :=
  Beam.Lean.Operation.all.map ToolName.ofLeanOperation

def ToolName.all : Array ToolName :=
  #[.leanInitWorkspace] ++ ToolName.leanOperationTools

def ToolName.key (tool : ToolName) : String :=
  match tool.leanOperation? with
  | some operation => leanOperationToolKey operation
  | none => "lean_init_workspace"

def ToolName.kind (tool : ToolName) : ToolKind :=
  match tool.leanOperation? with
  | some operation => .leanOperation operation
  | none => .workspaceInit

def ToolName.fromKey? (key : String) : Option ToolName :=
  ToolName.all.find? (fun tool => tool.key == key)

instance : ToJson ToolName where
  toJson tool := toJson tool.key

instance : FromJson ToolName where
  fromJson?
    | .str key =>
        match ToolName.fromKey? key with
        | some tool => .ok tool
        | none => .error s!"expected Lean MCP tool name, got {toJson key |>.compress}"
    | j => .error s!"expected Lean MCP tool name, got {j.compress}"

def ToolName.expectsRunAtResult (tool : ToolName) : Bool :=
  match tool.kind with
  | .leanOperation operation => operation.expectsRunAtResult
  | .workspaceInit => false

def ToolName.toBrokerRequest
    (tool : ToolName)
    (root : String)
    (input : Json) : Except String Beam.Broker.Request :=
  match tool.kind with
  | .leanOperation operation => operation.toBrokerRequest root input
  | .workspaceInit => throw s!"{tool.key} initializes MCP server state and does not map to a broker request"

def initWorkspaceDescription : String :=
  "Initialize, verify, or explicitly reset the Lean workspace root for MCP clients that cannot advertise roots/list."

def initWorkspaceModeDescription : String :=
  String.intercalate " " [
    "Workspace init mode. Defaults to set.",
    "Use reset to switch roots explicitly;",
    "reset discards the current runtime and invalidates handles from the previous root."
  ]

open Beam.JsonSchema in
def initWorkspaceInputSchema : Json :=
  inputObject [
    ("root", string "Absolute Lean/Lake project root path."),
    ("mode", enumString initWorkspaceModeDescription Beam.Workspace.initModeKeys)
  ] #["root"]

/-- Minimal descriptor for the MCP tool list. -/
structure ToolDescriptor where
  name : ToolName
  kind : ToolKind
  description : String
  inputSchema : Json

def toolNames : Array ToolName :=
  ToolName.all

def leanOperationToolNames : Array ToolName :=
  ToolName.leanOperationTools

def capabilityNames : Array String :=
  leanOperationToolNames.map (·.key)

def withCapabilities (json : Json) : Json :=
  json.setObjVal! "capabilities" (toJson capabilityNames)

def ToolName.descriptor (tool : ToolName) : ToolDescriptor :=
  match tool.kind with
  | .leanOperation op =>
      {
        name := tool
        kind := .leanOperation op
        description := op.description
        inputSchema := op.inputSchema
      }
  | .workspaceInit =>
      {
        name := tool
        kind := .workspaceInit
        description := initWorkspaceDescription
        inputSchema := initWorkspaceInputSchema
      }

def toolDescriptors : Array ToolDescriptor :=
  toolNames.map ToolName.descriptor

abbrev RunAtInput := Beam.Lean.RunAtInput
abbrev PositionInput := Beam.Lean.PositionInput
abbrev TodoInput := Beam.Lean.TodoInput
abbrev RunWithInput := Beam.Lean.RunWithInput
abbrev ReleaseInput := Beam.Lean.ReleaseInput
abbrev PathInput := Beam.Lean.PathInput
abbrev SyncInput := Beam.Lean.SyncInput
abbrev InitWorkspaceMode := Beam.Workspace.InitMode
abbrev InitWorkspaceInput := Beam.Workspace.InitInput

private def optionJson (value? : Option α) [ToJson α] : Json :=
  match value? with
  | some value => toJson value
  | none => Json.null

/-- Broker-level `runAt` result shape after the broker has wrapped any retained handle. -/
structure RunAtBrokerResult where
  success : Bool := true
  messages : Array RunAt.Message := #[]
  traces : Array String := #[]
  handle? : Option Beam.Broker.Handle := none
  proofState? : Option RunAt.ProofState := none

instance : FromJson RunAtBrokerResult where
  fromJson? j := do
    let success? ← optionalField? (α := Bool) j "success"
    let messages? ← optionalField? (α := Array RunAt.Message) j "messages"
    let traces? ← optionalField? (α := Array String) j "traces"
    let handle? ← optionalField? (α := Beam.Broker.Handle) j "handle"
    let proofState? ← optionalField? (α := RunAt.ProofState) j "proofState"
    pure {
      success := success?.getD true
      messages := messages?.getD #[]
      traces := traces?.getD #[]
      handle?
      proofState?
    }

structure ToolError where
  code : String
  message : String := ""
  data? : Option Json := none
  deriving ToJson

def ToolError.fromBrokerError (err : Beam.Broker.Error) : ToolError :=
  { code := err.code, message := err.message, data? := err.data? }

def ToolError.invalidEnvelope (message : String) : ToolError :=
  { code := "invalidEnvelope", message }

def ToolError.invalidResult (message : String) : ToolError :=
  { code := "invalidResult", message }

def ToolError.invalidInput (message : String) : ToolError :=
  { code := "invalidInput", message }

def ToolError.runtimeSetup (message : String) : ToolError :=
  { code := "runtimeSetup", message }

/--
Normalize a broker-level `runAt` result into the agent-facing field names.

The MCP surface uses `next_handle` and `proof_state` rather than the Lean/LSP payload's
`handle`/`proofState` names. `next_handle` is the broker-wrapped handle that follow-up tools pass
back unchanged.
-/
def runAtResultJson (result : RunAtBrokerResult) : Json :=
  Json.mkObj [
    ("success", toJson result.success),
    ("messages", toJson result.messages),
    ("traces", toJson result.traces),
    ("proof_state", optionJson result.proofState?),
    ("next_handle", optionJson result.handle?)
  ]

def normalizeRunAtResult (result : Json) : Except ToolError Json := do
  match fromJson? (α := RunAtBrokerResult) result with
  | .ok parsed => pure <| runAtResultJson parsed
  | .error err => throw <| ToolError.invalidResult err

private def todoItemKey (key : String) : String :=
  match key with
  | "runAtPosition" => "run_at_position"
  | "runAtText" => "run_at_text"
  | "codeAction" => "code_action"
  | "proofState" => "proof_state"
  | other => other

private def normalizeTodoItemJson : Json → Json
  | Json.obj fields =>
      let fields :=
        fields.foldl (init := []) fun acc key value =>
          (todoItemKey key, value) :: acc
      Json.mkObj fields.reverse
  | other => other

private def normalizeTodoResult (result : Json) : Except ToolError Json := do
  match result.getObjVal? "items" with
  | .ok (Json.arr items) =>
      pure <| result.setObjVal! "items" (Json.arr (items.map normalizeTodoItemJson))
  | .ok _ =>
      throw <| ToolError.invalidResult "todo result 'items' must be an array"
  | .error err =>
      throw <| ToolError.invalidResult s!"todo result missing 'items': {err}"

private def normalizeSyncResult (result : Json) : Except ToolError Json := do
  match result.getObjVal? "diagnostics" with
  | .ok (Json.arr diagnostics) =>
      let diagnostics ← diagnostics.mapM fun rawDiagnosticJson =>
        match fromJson? (α := Beam.Broker.StreamDiagnostic) rawDiagnosticJson with
        | .ok diagnostic => pure <| diagnosticJson diagnostic
        | .error err => throw <| ToolError.invalidResult s!"sync diagnostic result is invalid: {err}"
      pure <| result.setObjVal! "diagnostics" (Json.arr diagnostics)
  | .ok _ =>
      throw <| ToolError.invalidResult "sync result 'diagnostics' must be an array"
  | .error _ =>
      pure result

private def normalizeResult? (tool : ToolName) : Option Json → Except ToolError (Option Json)
  | none => pure none
  | some result =>
      if tool.expectsRunAtResult then do
        let normalized ← normalizeRunAtResult result
        pure <| some normalized
      else if tool == .leanTodo then do
        let normalized ← normalizeTodoResult result
        pure <| some normalized
      else if tool == .leanSync then do
        let normalized ← normalizeSyncResult result
        pure <| some normalized
      else
        pure <| some result

private def ensureObject (json : Json) : Json :=
  match json with
  | .obj _ => json
  | other => Json.mkObj [("result", other)]

private def withMetadata
    (json : Json)
    (fileProgress? : Option Beam.Broker.SyncFileProgress)
    (clientRequestId? : Option String) : Json :=
  let json := ensureObject json
  let json :=
    match fileProgress? with
    | some progress => json.setObjVal! "file_progress" (toJson progress)
    | none => json
  match clientRequestId? with
  | some clientRequestId => json.setObjVal! "client_request_id" (toJson clientRequestId)
  | none => json

/--
Normalize a broker response into MCP tool result content.

Broker-level failures become `ToolError`s so an MCP server can map them to tool/JSON-RPC errors.
Semantic Lean failures remain normal tool results with `success = false`.
-/
def normalizeBrokerResponse (tool : ToolName) (resp : Beam.Broker.Response) : Except ToolError Json := do
  if resp.ok && resp.error?.isSome then
    throw <| ToolError.invalidEnvelope "ok=true must not include an error"
  if !resp.ok && resp.error?.isNone then
    throw <| ToolError.invalidEnvelope "ok=false must include an error"
  if !resp.ok && resp.result?.isSome then
    throw <| ToolError.invalidEnvelope "ok=false must not include a result"
  if !resp.ok then
    let some err := resp.error?
      | throw <| ToolError.invalidEnvelope "ok=false must include an error"
    throw <| ToolError.fromBrokerError err
  let result? ← normalizeResult? tool resp.result?
  pure <| withMetadata (result?.getD (Json.mkObj [])) resp.fileProgress? resp.clientRequestId?

end Beam.Mcp
