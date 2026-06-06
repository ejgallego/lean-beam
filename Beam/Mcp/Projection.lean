/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation
import Beam.Mcp.Json
import RunAt.Protocol

open Lean

namespace Beam.Mcp

/--
Agent-facing MCP tool names supported by the planned Lean projection.

This is intentionally smaller than the broker and LSP surfaces. In particular, raw LSP method names
such as `$/lean/runAt` are not accepted here.
-/
inductive ToolName where
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

def ToolName.operation : ToolName → Beam.Lean.Operation
  | .leanRunAt => .runAt
  | .leanRunAtHandle => .runAtHandle
  | .leanHover => .hover
  | .leanGoalsAfter => .goalsAfter
  | .leanGoalsPrev => .goalsPrev
  | .leanRunWith => .runWith
  | .leanRunWithLinear => .runWithLinear
  | .leanRelease => .release
  | .leanSync => .sync
  | .leanDeps => .deps
  | .leanSave => .save
  | .leanClose => .close

def ToolName.expectsRunAtResult (tool : ToolName) : Bool :=
  tool.operation.expectsRunAtResult

def ToolName.toBrokerRequest
    (tool : ToolName)
    (root : String)
    (input : Json) : Except String Beam.Broker.Request :=
  tool.operation.toBrokerRequest root input

/-- Minimal descriptor for the planned MCP tool list. -/
structure ToolDescriptor where
  name : ToolName
  operation : Beam.Lean.Operation
  brokerOp : Beam.Broker.Op
  description : String
  inputSchema : Json
  deriving ToJson

def toolNames : Array ToolName := #[
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
  let op := tool.operation
  {
    name := tool
    operation := op
    brokerOp := op.brokerOp
    description := op.description
    inputSchema := op.inputSchema
  }

def toolDescriptors : Array ToolDescriptor :=
  toolNames.map ToolName.descriptor

abbrev RunAtInput := Beam.Lean.RunAtInput
abbrev PositionInput := Beam.Lean.PositionInput
abbrev RunWithInput := Beam.Lean.RunWithInput
abbrev ReleaseInput := Beam.Lean.ReleaseInput
abbrev PathInput := Beam.Lean.PathInput
abbrev SyncInput := Beam.Lean.SyncInput

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
