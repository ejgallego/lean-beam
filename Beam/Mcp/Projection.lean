/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation
import Beam.JsonSchema
import Beam.Mcp.Json
import Beam.Workspace
import RunAt.Protocol

open Lean

namespace Beam.Mcp

/--
Agent-facing MCP tool names supported by the planned Lean projection.

This is intentionally smaller than the broker and LSP surfaces. In particular, raw LSP method names
such as `$/lean/runAt` are not accepted here.
-/
inductive ToolName where
  | leanInitWorkspace
  | leanRunAt
  | leanRunAtHandle
  | leanHover
  | leanGoalsAfter
  | leanGoalsPrev
  | leanRunWith
  | leanRunWithLinear
  | leanRelease
  | leanSync
  | leanDeps
  | leanSave
  | leanClose
  deriving BEq, Repr

def ToolName.key : ToolName → String
  | .leanInitWorkspace => "lean_init_workspace"
  | .leanRunAt => "lean_run_at"
  | .leanRunAtHandle => "lean_run_at_handle"
  | .leanHover => "lean_hover"
  | .leanGoalsAfter => "lean_goals_after"
  | .leanGoalsPrev => "lean_goals_prev"
  | .leanRunWith => "lean_run_with"
  | .leanRunWithLinear => "lean_run_with_linear"
  | .leanRelease => "lean_release"
  | .leanSync => "lean_sync"
  | .leanDeps => "lean_deps"
  | .leanSave => "lean_save"
  | .leanClose => "lean_close"

instance : ToJson ToolName where
  toJson tool := toJson tool.key

instance : FromJson ToolName where
  fromJson?
    | .str "lean_init_workspace" => .ok .leanInitWorkspace
    | .str "lean_run_at" => .ok .leanRunAt
    | .str "lean_run_at_handle" => .ok .leanRunAtHandle
    | .str "lean_hover" => .ok .leanHover
    | .str "lean_goals_after" => .ok .leanGoalsAfter
    | .str "lean_goals_prev" => .ok .leanGoalsPrev
    | .str "lean_run_with" => .ok .leanRunWith
    | .str "lean_run_with_linear" => .ok .leanRunWithLinear
    | .str "lean_release" => .ok .leanRelease
    | .str "lean_sync" => .ok .leanSync
    | .str "lean_deps" => .ok .leanDeps
    | .str "lean_save" => .ok .leanSave
    | .str "lean_close" => .ok .leanClose
    | j => .error s!"expected Lean MCP tool name, got {j.compress}"

/-- MCP tool categories after projecting the shared Beam operation surface. -/
inductive ToolKind where
  | workspaceInit
  | leanOperation (operation : Beam.Lean.Operation)
  deriving BEq, Repr

def ToolName.kind : ToolName → ToolKind
  | .leanInitWorkspace => .workspaceInit
  | .leanRunAt => .leanOperation .runAt
  | .leanRunAtHandle => .leanOperation .runAtHandle
  | .leanHover => .leanOperation .hover
  | .leanGoalsAfter => .leanOperation .goalsAfter
  | .leanGoalsPrev => .leanOperation .goalsPrev
  | .leanRunWith => .leanOperation .runWith
  | .leanRunWithLinear => .leanOperation .runWithLinear
  | .leanRelease => .leanOperation .release
  | .leanSync => .leanOperation .sync
  | .leanDeps => .leanOperation .deps
  | .leanSave => .leanOperation .save
  | .leanClose => .leanOperation .close

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
  "Initialize the Lean workspace root for MCP clients that cannot advertise roots/list."

open Beam.JsonSchema in
def initWorkspaceInputSchema : Json :=
  inputObject [
    ("root", string "Absolute Lean/Lake project root path."),
    ("mode", enumString "Workspace init mode. Defaults to set." Beam.Workspace.initModeKeys)
  ] #["root"]

/-- Minimal descriptor for the planned MCP tool list. -/
structure ToolDescriptor where
  name : ToolName
  kind : ToolKind
  description : String
  inputSchema : Json

def toolNames : Array ToolName := #[
  .leanInitWorkspace,
  .leanRunAt,
  .leanRunAtHandle,
  .leanHover,
  .leanGoalsAfter,
  .leanGoalsPrev,
  .leanRunWith,
  .leanRunWithLinear,
  .leanRelease,
  .leanSync,
  .leanDeps,
  .leanSave,
  .leanClose
]

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
Normalize a broker-level `runAt` result into the planned agent-facing field names.

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

private def normalizeResult? (tool : ToolName) : Option Json → Except ToolError (Option Json)
  | none => pure none
  | some result =>
      if tool.expectsRunAtResult then do
        let normalized ← normalizeRunAtResult result
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
Normalize a broker response into the future MCP tool result content.

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
