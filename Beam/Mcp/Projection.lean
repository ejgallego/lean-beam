/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation
import Beam.Feedback
import Beam.JsonSchema
import Beam.Mcp.Json
import Beam.Version
import Beam.Workspace
import Beam.LSP.Lib.Goal
import Beam.LSP.RunAt

open Lean

namespace Beam.Mcp

/--
Agent-facing MCP tool names supported by the Lean projection.

This is intentionally smaller than the broker and LSP surfaces. In particular, raw LSP method names
such as `$/lean/runAt` are not accepted here.
-/
inductive ToolName where
  | beamVersion
  | beamStats
  | beamFeedbackReport
  | leanDropWorkspace
  | leanOperation (operation : Beam.Lean.Operation)
  deriving BEq, Repr

/-- MCP tool categories after projecting the shared Beam operation surface. -/
inductive ToolKind where
  | serverInfo
  | serverDebug
  | feedback
  | workspaceDrop
  | leanOperation (operation : Beam.Lean.Operation)
  deriving BEq, Repr

def ToolName.ofLeanOperation (operation : Beam.Lean.Operation) : ToolName :=
  .leanOperation operation

def ToolName.leanRunAt : ToolName := .leanOperation .runAt
def ToolName.leanRunAtHandle : ToolName := .leanOperation .runAtHandle
def ToolName.leanHover : ToolName := .leanOperation .hover
def ToolName.leanSignatureHelp : ToolName := .leanOperation .signatureHelp
def ToolName.leanDefinition : ToolName := .leanOperation .definition
def ToolName.leanReferences : ToolName := .leanOperation .references
def ToolName.leanDocumentSymbols : ToolName := .leanOperation .documentSymbols
def ToolName.leanWorkspaceSymbols : ToolName := .leanOperation .workspaceSymbols
def ToolName.leanGoals : ToolName := .leanOperation .goals
def ToolName.leanTodo : ToolName := .leanOperation .todo
def ToolName.leanCodeActionResolve : ToolName := .leanOperation .codeActionResolve
def ToolName.leanRunWith : ToolName := .leanOperation .runWith
def ToolName.leanRunWithLinear : ToolName := .leanOperation .runWithLinear
def ToolName.leanRelease : ToolName := .leanOperation .release
def ToolName.leanUpdate : ToolName := .leanOperation .update
def ToolName.leanSync : ToolName := .leanOperation .sync
def ToolName.leanRefresh : ToolName := .leanOperation .refresh
def ToolName.leanSave : ToolName := .leanOperation .save
def ToolName.leanCloseSave : ToolName := .leanOperation .closeSave
def ToolName.leanClose : ToolName := .leanOperation .close

private def leanOperationToolKey (operation : Beam.Lean.Operation) : String :=
  "lean_" ++ operation.key

def ToolName.leanOperationTools : Array ToolName :=
  Beam.Lean.Operation.all.map ToolName.ofLeanOperation

def ToolName.all : Array ToolName :=
  #[
    .beamVersion,
    .beamStats,
    .beamFeedbackReport,
    .leanDropWorkspace
  ] ++ ToolName.leanOperationTools

def ToolName.key (tool : ToolName) : String :=
  match tool with
  | .beamVersion => "beam_version"
  | .beamStats => "beam_stats"
  | .beamFeedbackReport => "beam_feedback_report"
  | .leanDropWorkspace => "lean_drop_workspace"
  | .leanOperation operation => leanOperationToolKey operation

def ToolName.kind (tool : ToolName) : ToolKind :=
  match tool with
  | .beamVersion => .serverInfo
  | .beamStats => .serverDebug
  | .beamFeedbackReport => .feedback
  | .leanDropWorkspace => .workspaceDrop
  | .leanOperation operation => .leanOperation operation

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
  | .serverInfo => false
  | .serverDebug => false
  | .feedback => false
  | .workspaceDrop => false

def leanOperationToBrokerRequest
    (operation : Beam.Lean.Operation)
    (root : String)
    (workspaceId : Beam.Workspace.WorkspaceId)
    (input : Json) : Except String Beam.Broker.Request := do
  let req ← operation.toBrokerRequest root input
  pure { req with workspaceId? := some workspaceId }

def beamVersionDescription : String :=
  "Return the running Lean Beam MCP server identity for bug reports and refresh checks."

def beamStatsDescription : String :=
  "Return process-wide debug Beam broker runtime statistics for lazily cached workspaces."

def beamFeedbackReportDescription : String :=
  String.intercalate " " [
    "Beam does not upload or submit feedback. This tool creates and returns a pasteable feedback report for one explicit workspace.",
    "Non-confidential output may contain project context and caller payloads, so review it before posting.",
    "Set confidential for non-public workspaces; confidential results retain caller-authored narrative",
    "except for HOME-path redaction and do not scan it for other secrets; never post them publicly.",
    "A local evidence bundle is optional.",
    "For detailed live updates, clients can pass `tools/call` `_meta.progressToken`; without one,",
    "Beam emits one status log when collection is delayed and the request's logging policy admits notice-level events."
  ]

open Beam.JsonSchema in
def emptyInputSchema : Json :=
  inputObject [] #[]

private def anyJsonSchema (description : String) : Json :=
  Json.mkObj [
    ("description", toJson description)
  ]

private def arraySchema (description : String) (items : Json) : Json :=
  Json.mkObj [
    ("type", toJson "array"),
    ("description", toJson description),
    ("items", items)
  ]

private def evidenceInputSchema : Json :=
  Json.mkObj [
    ("type", toJson "object"),
    ("description", toJson "Optional inline or file evidence to copy into a feedback bundle."),
    ("properties", Json.mkObj [
      ("name", Beam.JsonSchema.string "Simple evidence filename, without path separators."),
      ("content", anyJsonSchema "Inline JSON or text evidence to write into the bundle."),
      ("path", Beam.JsonSchema.string "Path to a local evidence file under the known root or Beam control directory.")
    ]),
    ("required", toJson (#[("name" : String)] : Array String)),
    ("additionalProperties", toJson false)
  ]

private def workspaceDescriptorSchema : Json :=
  Json.mkObj [
    ("type", toJson "object"),
    ("description", toJson "Explicit local Lean workspace descriptor."),
    ("properties", Json.mkObj [
      ("root", Beam.JsonSchema.string "Absolute Lean/Lake project root path.")
    ]),
    ("required", toJson (#["root"] : Array String)),
    ("additionalProperties", toJson false)
  ]

open Beam.JsonSchema in
def feedbackReportInputSchema : Json :=
  inputObject [
    ("workspace", workspaceDescriptorSchema),
    ("title", string "Short report title."),
    ("summary", string "What went wrong or what feedback should be reviewed."),
    ("reproduction", string "Concrete steps or commands needed to reproduce the behavior."),
    ("expected", string "Expected behavior."),
    ("actual", string "Observed behavior."),
    ("kind", enumString "Optional triage category." Beam.Feedback.reportKindKeys),
    ("severity", enumString "Optional triage severity." Beam.Feedback.reportSeverityKeys),
    ("impact", string "Optional user impact."),
    ("workaround", string "Optional workaround."),
    ("tags", arraySchema "Optional short labels for routing the report." (string "Feedback tag.")),
    ("client_request_id", string "Optional caller-side correlation id."),
    ("request", object "Optional request payload relevant to the report."),
    ("response", object "Optional response payload relevant to the report."),
    ("evidence", arraySchema "Optional evidence entries to include in a bundle." evidenceInputSchema),
    ("bundle", enumString "Optional evidence bundle mode. Defaults to none." Beam.Feedback.bundleModeKeys),
    ("redact", bool "Whether to redact the user's home directory from the rendered report. Defaults to true."),
    ("confidential", bool "Set true for a non-public workspace. Forces HOME-path redaction; omits automatically collected project debug context, caller-supplied request, response, evidence, and the echoed workspace descriptor; retains other caller-authored narrative without scanning it for arbitrary secrets; and marks the report as confidential. Defaults to false."),
    ("include_collected", bool "When true, include collected Beam debug context inline in the MCP result. In confidential mode, include only the restricted runtime identity. Defaults to false.")
  ] (Beam.Feedback.requiredInputFields.push "workspace")

def dropWorkspaceDescription : String :=
  "Evict one local Lean workspace cache and invalidate its retained proof handles. A later request recreates it lazily. For detailed live updates, clients can pass `tools/call` `_meta.progressToken`; without one, Beam emits one status log when eviction is delayed and the request's logging policy admits notice-level events."

open Beam.JsonSchema in
def dropWorkspaceInputSchema : Json :=
  inputObject [
    ("workspace", workspaceDescriptorSchema)
  ] #["workspace"]

private def schemaWithWorkspace (schema : Json) : Json :=
  match Beam.JsonSchema.withRequiredProperty schema "workspace" workspaceDescriptorSchema with
  | .ok schema => schema
  | .error err => panic! s!"invalid generated Lean operation schema: {err}"

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

def ToolName.descriptor (tool : ToolName) : ToolDescriptor :=
  match tool.kind with
  | .serverInfo =>
      {
        name := tool
        kind := .serverInfo
        description := beamVersionDescription
        inputSchema := emptyInputSchema
      }
  | .serverDebug =>
      {
        name := tool
        kind := .serverDebug
        description := beamStatsDescription
        inputSchema := emptyInputSchema
      }
  | .feedback =>
      {
        name := tool
        kind := .feedback
        description := beamFeedbackReportDescription
        inputSchema := feedbackReportInputSchema
      }
  | .leanOperation op =>
      {
        name := tool
        kind := .leanOperation op
        description := op.description
        inputSchema := schemaWithWorkspace op.inputSchema
      }
  | .workspaceDrop =>
      {
        name := tool
        kind := .workspaceDrop
        description := dropWorkspaceDescription
        inputSchema := dropWorkspaceInputSchema
      }

def toolDescriptors : Array ToolDescriptor :=
  toolNames.map ToolName.descriptor

/-- Reject fields outside the closed schema advertised for one MCP tool. -/
def ToolName.validateInputFields (tool : ToolName) (input : Json) : Except String Unit := do
  let properties ← tool.descriptor.inputSchema.getObjVal? "properties"
  match properties with
  | .obj _ => pure ()
  | other => throw s!"{tool.key} input schema properties must be an object, got {other.compress}"
  match input with
  | .obj fields =>
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if (properties.getObjVal? field).isOk then
          unexpected
        else
          unexpected.push field
      unless unexpected.isEmpty do
        throw s!"{tool.key} accepts no undeclared input fields: {String.intercalate ", " unexpected.toList}"
  | other =>
      throw s!"{tool.key} input must be an object, got {other.compress}"

abbrev RunAtInput := Beam.Lean.RunAtInput
abbrev PositionInput := Beam.Lean.PositionInput
abbrev ReferencesInput := Beam.Lean.ReferencesInput
abbrev DocumentSymbolsInput := Beam.Lean.DocumentSymbolsInput
abbrev WorkspaceSymbolsInput := Beam.Lean.WorkspaceSymbolsInput
abbrev GoalsInput := Beam.Lean.GoalsInput
abbrev TodoInput := Beam.Lean.TodoInput
abbrev CodeActionResolveInput := Beam.Lean.CodeActionResolveInput
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
  messages : Array Beam.LSP.RunAt.Message := #[]
  traces : Array String := #[]
  handle? : Option Beam.Broker.Handle := none
  proofState? : Option Beam.LSP.Lib.ProofState := none

instance : FromJson RunAtBrokerResult where
  fromJson? j := do
    let success? ← optionalField? (α := Bool) j "success"
    let messages? ← optionalField? (α := Array Beam.LSP.RunAt.Message) j "messages"
    let traces? ← optionalField? (α := Array String) j "traces"
    let handle? ← optionalField? (α := Beam.Broker.Handle) j "handle"
    let proofState? ← optionalField? (α := Beam.LSP.Lib.ProofState) j "proofState"
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

private def normalizeCodeActionResolveResult : Json → Except ToolError Json
  | Json.obj fields =>
      let fields :=
        fields.foldl (init := []) fun acc key value =>
          let key :=
            if key == "codeAction" then
              "code_action"
            else
              key
          (key, value) :: acc
      pure <| Json.mkObj fields.reverse
  | other =>
      throw <| ToolError.invalidResult
        s!"code_action_resolve result must be an object, got {other.compress}"

private def diagnosticSeverityName : Option Lean.Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "information"
  | some .hint => "hint"
  | none => "unknown"

private def mcpDiagnosticJson (diagnostic : Beam.Broker.StreamDiagnostic) : Json :=
  Json.mkObj <|
    [
      ("path", toJson diagnostic.path),
      ("uri", toJson diagnostic.uri),
      ("severity", toJson <| diagnosticSeverityName diagnostic.severity?),
      ("range", toJson diagnostic.range),
      ("message", toJson diagnostic.message),
      ("completionBlocking", toJson diagnostic.completionBlocking)
    ] ++
    (match diagnostic.saveBlocking? with
    | some saveBlocking => [("saveBlocking", toJson saveBlocking)]
    | none => []) ++
    match diagnostic.version? with
    | some version => [("version", toJson version)]
    | none => []

private def normalizeSyncResult (result : Json) : Except ToolError Json := do
  match result.getObjVal? "diagnostics" with
  | .ok (Json.arr diagnostics) =>
      let diagnostics ← diagnostics.mapM fun diagnosticJson =>
        match fromJson? (α := Beam.Broker.StreamDiagnostic) diagnosticJson with
        | .ok diagnostic => pure <| mcpDiagnosticJson diagnostic
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
      else if tool == .leanCodeActionResolve then do
        let normalized ← normalizeCodeActionResolveResult result
        pure <| some normalized
      else if tool == .leanSync || tool == .leanRefresh then do
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
