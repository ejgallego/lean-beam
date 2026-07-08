/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Feedback
import Beam.Feedback.Broker
import Beam.Daemon.Debug
import Beam.Lean.Workspace
import Beam.Mcp.Options
import Beam.Mcp.Protocol
import Beam.Mcp.Runtime
import Beam.Mcp.Roots
import Beam.Mcp.SelfCheck
import Beam.Mcp.Stdio
import Beam.System
import Beam.Workspace
import Beam.Version

open Lean

namespace Beam.Mcp.Server

structure ProtocolState where
  initializeComplete : Bool := false
  initializedNotificationSeen : Bool := false
  clientSupportsRoots : Bool := false
  logLevel : LogLevel := .debug
  root? : Option System.FilePath := none
  rootError? : Option String := none
  workspaces : Std.TreeMap Beam.Broker.WorkspaceId System.FilePath := {}
  runtime? : Option Beam.Broker.ServerRuntime := none

def ProtocolState.create (root? : Option System.FilePath := none) : IO (IO.Ref ProtocolState) :=
  IO.mkRef { root? }

structure NotificationSink where
  send : Json → IO Unit := fun _ => pure ()

private structure Notifier where
  state : IO.Ref ProtocolState
  sink : NotificationSink

private def Notifier.send (notifier : Notifier) (json : Json) : IO Unit :=
  notifier.sink.send json

abbrev Options := Beam.Mcp.Options

private def traceEnabled (envName : String) : IO Bool := do
  match ← IO.getEnv envName with
  | some value => pure (!value.isEmpty && value != "0")
  | none => pure false

private def traceMcp (message : String) : IO Unit := do
  if ← traceEnabled "LEAN_BEAM_MCP_TRACE" then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: {message}"

private def outgoingJsonLabel (json : Json) : String :=
  let idLabel :=
    match json.getObjVal? "id" with
    | .ok id => requestIdLabel id
    | .error _ => "<none>"
  let methodLabel :=
    match json.getObjVal? "method" with
    | .ok (.str method) => method
    | .ok method => method.compress
    | .error _ => "<none>"
  let kind :=
    if methodLabel != "<none>" then
      "method"
    else if (json.getObjVal? "error").isOk then
      "error"
    else
      "response"
  s!"kind={kind} id={idLabel} method={methodLabel}"

private def writeJsonLine (json : Json) : IO Unit := do
  let payload := json.compress
  let trace := ← traceEnabled "LEAN_BEAM_MCP_TRACE"
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write start {outgoingJsonLabel json} chars={payload.length}"
  let stdout ← IO.getStdout
  stdout.putStr (payload ++ "\n")
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write putStr done {outgoingJsonLabel json}"
  stdout.flush
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write flush done {outgoingJsonLabel json}"

private structure ProgressEmitter where
  progressToken : Json
  nextProgress : IO.Ref Nat
  lastFileProgress : IO.Ref (Option Beam.Broker.SyncFileProgress)
  emitNotification : Json → IO Unit

private def fileProgressUpdateStride : Nat :=
  25

private def fileProgressMessage (tool : ToolName) (progress : Beam.Broker.SyncFileProgress) : String :=
  s!"{tool.key} fileProgress {Beam.Broker.SyncFileProgress.displayDetails progress}"

private def shouldEmitFileProgress
    (last? : Option Beam.Broker.SyncFileProgress)
    (progress : Beam.Broker.SyncFileProgress) : Bool :=
  match last? with
  | none => true
  | some last =>
      (progress.done && progress != last) ||
        progress.updates >= last.updates + fileProgressUpdateStride

private def ProgressEmitter.create?
    (progressToken? : Option Json)
    (emitNotification : Json → IO Unit) : IO (Option ProgressEmitter) := do
  match progressToken? with
  | none => pure none
  | some progressToken =>
      pure <| some {
        progressToken
        nextProgress := ← IO.mkRef 0
        lastFileProgress := ← IO.mkRef none
        emitNotification
      }

private def ProgressEmitter.emit
    (emitter : ProgressEmitter)
    (message : String)
    (total? : Option Nat := none) : IO Unit := do
  let current ← emitter.nextProgress.get
  let next := current + 1
  emitter.nextProgress.set next
  emitter.emitNotification <| progressNotification emitter.progressToken next (some message) total?

private def ProgressEmitter.emitFileProgress
    (emitter : ProgressEmitter)
    (tool : ToolName)
    (fileProgress : Beam.Broker.SyncFileProgress) : IO Unit := do
  let last? ← emitter.lastFileProgress.get
  if shouldEmitFileProgress last? fileProgress then
    emitter.lastFileProgress.set (some fileProgress)
    emitter.emit (fileProgressMessage tool fileProgress)

private def emitProgress?
    (progress? : Option ProgressEmitter)
    (message : String)
    (total? : Option Nat := none) : IO Unit := do
  match progress? with
  | some progress => progress.emit message total?
  | none => pure ()

private def invalidRequestId (json : Json) : Json :=
  match json.getObjVal? "id" with
  | .ok id =>
      if validRequestId id then id else Json.null
  | .error _ => Json.null

private def brokerClientRequestId (req : Request) : String :=
  s!"mcp:{requestIdLabel req.id}"

private def diagnosticSeverityName : Option Lean.Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "information"
  | some .hint => "hint"
  | none => "unknown"

private def diagnosticLogLevel : Option Lean.Lsp.DiagnosticSeverity → LogLevel
  | some .error => .error
  | some .warning => .warning
  | some .information => .info
  | some .hint => .debug
  | none => .info

private def streamDiagnosticLogData (diagnostic : Beam.Broker.StreamDiagnostic) : Json :=
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

private def emitDiagnosticLog
    (notifier : Notifier)
    (diagnostic : Beam.Broker.StreamDiagnostic) : IO Unit := do
  let level := diagnosticLogLevel diagnostic.severity?
  let currentState ← notifier.state.get
  if currentState.logLevel.allows level then
    notifier.send <|
      logMessageNotification level "lean.diagnostic" (streamDiagnosticLogData diagnostic)

private def runtimeOptions (opts : Options) : Runtime.Options := {
  leanCmd? := opts.leanCmd?
  leanPlugin? := opts.leanPlugin?
  beamCli? := opts.beamCli?
}

private def createRuntimeForRoot
    (opts : Options)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) :
    IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  match ← Runtime.mkBrokerConfig (runtimeOptions opts) root with
  | .error err =>
      pure <| .error err
  | .ok config =>
      try
        let runtime ← Beam.Broker.ServerRuntime.create config workspaceId
        pure <| .ok (runtime, config.root)
      catch e =>
        pure <| .error <| runtimeSetupError e.toString

private def ensureRoot
    (state : IO.Ref ProtocolState)
    (stdin : IO.FS.Stream)
    (notifier : Notifier) : IO (Except RpcError System.FilePath) := do
  let currentState ← state.get
  match currentState.rootError? with
  | some err =>
      pure <| .error <| RpcError.invalidRequest err
  | none =>
      match currentState.root? with
      | some root => pure <| .ok root
      | none =>
          let root? ←
            if currentState.clientSupportsRoots then
              Roots.requestClientRoot stdin notifier.send
            else
              pure <| .error Roots.unsupportedMessage
          match root? with
          | .error err =>
              state.modify fun state => { state with rootError? := some err }
              pure <| .error <| RpcError.invalidRequest err
          | .ok root =>
              state.modify fun state => { state with root? := some root }
              pure <| .ok root

private def ensureBrokerWorkspace
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (runtime : Beam.Broker.ServerRuntime)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) : IO (Except RpcError System.FilePath) := do
  let currentState ← state.get
  match currentState.workspaces.get? workspaceId with
  | some trackedRoot =>
      if trackedRoot == root then
        pure <| .ok root
      else
        pure <| .error <| RpcError.invalidRequest
          s!"workspace '{workspaceId}' is already initialized for {trackedRoot}, not {root}"
  | none =>
      match ← Runtime.mkBrokerConfig (runtimeOptions opts) root with
      | .error err =>
          state.modify fun state => { state with rootError? := some err.message }
          pure <| .error err
      | .ok config =>
          let brokerResp ← runtime.initWorkspaceWithConfig workspaceId config (some "set")
          if brokerResp.ok then
            state.modify fun state => {
              state with
              root? :=
                if workspaceId == Beam.Broker.defaultWorkspaceId then
                  some config.root
                else
                  state.root?
              rootError? := none
              workspaces := state.workspaces.insert workspaceId config.root
            }
            pure <| .ok config.root
          else
            let message := (brokerResp.error?.map (·.message)).getD
              s!"failed to initialize workspace '{workspaceId}'"
            pure <| .error <| RpcError.invalidRequest message

private def ensureRuntime
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (notifier : Notifier) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  let currentState ← state.get
  match currentState.runtime?, currentState.root? with
  | some runtime, some root =>
      match ← ensureBrokerWorkspace state opts runtime Beam.Broker.defaultWorkspaceId root with
      | .ok root => pure <| .ok (runtime, root)
      | .error err => pure <| .error err
  | _, _ =>
      match ← ensureRoot state stdin notifier with
      | .error err => pure <| .error err
      | .ok root =>
          match ← createRuntimeForRoot opts Beam.Broker.defaultWorkspaceId root with
          | .error err =>
              state.modify fun state => { state with rootError? := some err.message }
              pure <| .error err
          | .ok (runtime, root) =>
              state.modify fun state => {
                state with
                root? := some root
                runtime? := some runtime
                workspaces := state.workspaces.insert Beam.Broker.defaultWorkspaceId root
              }
              pure <| .ok (runtime, root)

private def ensureRuntimeForWorkspace
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (notifier : Notifier)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  if workspaceId == Beam.Broker.defaultWorkspaceId then
    ensureRuntime state opts stdin notifier
  else
    let currentState ← state.get
    match currentState.runtime? with
    | some runtime => pure <| .ok (runtime, root)
    | none =>
        pure <| .error <| RpcError.invalidRequest
          s!"workspace '{workspaceId}' is not initialized; call lean_init_workspace with workspace_id first"

private def workspaceErrorToToolError (err : Beam.Workspace.InitError) : ToolError :=
  let data? := err.activeRoot?.map fun activeRoot =>
    Json.mkObj [("active_root", toJson activeRoot.toString)]
  { ToolError.invalidInput err.message with data? }

private def shutdownRuntimeForReset (runtime : Beam.Broker.ServerRuntime) : IO (Except ToolError Unit) := do
  let (brokerResp, _) ← runtime.dispatchRequest { op := .shutdown }
  if brokerResp.ok then
    pure <| .ok ()
  else
    let message := (brokerResp.error?.map (·.message)).getD "Beam broker shutdown failed"
    pure <| .error <| ToolError.runtimeSetup s!"failed to reset MCP workspace: {message}"

private def resetRuntimeHandoff
    (oldRuntime? : Option Beam.Broker.ServerRuntime)
    (newRuntime : Beam.Broker.ServerRuntime) : IO (Except ToolError Unit) := do
  match oldRuntime? with
  | none => pure <| .ok ()
  | some oldRuntime =>
      match ← shutdownRuntimeForReset oldRuntime with
      | .ok () => pure <| .ok ()
      | .error err =>
          discard <| shutdownRuntimeForReset newRuntime
          pure <| .error err

private def handleInitWorkspace
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  let input ←
    match fromJson? (α := InitWorkspaceInput) arguments with
    | .ok input => pure input
    | .error err =>
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let requestedRoot ←
    match ← Beam.Lean.Workspace.resolveRoot input.root with
    | .ok root => pure root
    | .error err =>
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| workspaceErrorToToolError err
  let mode := input.mode
  let modeKey := mode.key
  let workspaceId := input.workspaceId
  let currentState ← state.get
  let config ←
    match ← Runtime.mkBrokerConfig (runtimeOptions opts) requestedRoot with
    | .error err =>
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| ToolError.runtimeSetup err.message
    | .ok config => pure config
  let finalizeSuccess (payload : Json) (root : System.FilePath) : IO Json := do
    state.modify fun currentState => {
      currentState with
      root? :=
        if workspaceId == Beam.Broker.defaultWorkspaceId then
          some root
        else
          currentState.root?
      rootError? := none
      workspaces := currentState.workspaces.insert workspaceId root
    }
    emitProgress? progress? "completed lean_init_workspace"
    pure <| callToolResult <| withCapabilities payload
  let toolErrorOfBroker (resp : Beam.Broker.Response) : ToolError :=
    match resp.error? with
    | some err => ToolError.fromBrokerError err
    | none => ToolError.runtimeSetup "workspace initialization failed without a typed broker error"
  match currentState.runtime? with
  | none =>
      if mode == .verify then
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| ToolError.invalidInput
          s!"workspace '{workspaceId}' is not initialized; use mode=set first"
      emitProgress? progress? "starting workspace runtime"
      match ← createRuntimeForRoot opts workspaceId requestedRoot with
      | .error err =>
          emitProgress? progress? "lean_init_workspace failed"
          return callToolErrorResult <| ToolError.runtimeSetup err.message
      | .ok (runtime, root) =>
          state.modify fun currentState => { currentState with runtime? := some runtime }
          finalizeSuccess
            (Beam.Broker.workspaceInitPayload workspaceId root modeKey false false)
            root
  | some runtime =>
      emitProgress? progress? "initializing workspace runtime"
      let brokerResp ← runtime.initWorkspaceWithConfig workspaceId config (some modeKey)
      if brokerResp.ok then
        match brokerResp.result? with
        | some payload => finalizeSuccess payload config.root
        | none =>
            emitProgress? progress? "lean_init_workspace failed"
            return callToolErrorResult <| ToolError.invalidResult
              "workspace initialization succeeded without a result payload"
      else
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| toolErrorOfBroker brokerResp

private def droppedDefaultWorkspaceMessage : String :=
  "default Beam workspace was dropped; call lean_init_workspace with workspace_id \"default\" to recreate it"

private def handleListWorkspaces
    (state : IO.Ref ProtocolState)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  match requireEmptyInput "lean_list_workspaces" arguments with
  | .error err =>
      emitProgress? progress? "lean_list_workspaces failed"
      return callToolErrorResult <| ToolError.invalidInput err
  | .ok () => pure ()
  let currentState ← state.get
  match currentState.runtime? with
  | none =>
      emitProgress? progress? "completed lean_list_workspaces"
      pure <| callToolResult <| Json.mkObj [("workspaces", Json.arr #[])]
  | some runtime =>
      let (brokerResp, _) ← runtime.dispatchRequest { op := .listWorkspaces }
      if brokerResp.ok then
        match brokerResp.result? with
        | some payload =>
            emitProgress? progress? "completed lean_list_workspaces"
            pure <| callToolResult payload
        | none =>
            emitProgress? progress? "lean_list_workspaces failed"
            pure <| callToolErrorResult <|
              ToolError.invalidResult "workspace listing succeeded without a result payload"
      else
        emitProgress? progress? "lean_list_workspaces failed"
        let err :=
          match brokerResp.error? with
          | some err => ToolError.fromBrokerError err
          | none => ToolError.runtimeSetup "workspace listing failed without a typed broker error"
        pure <| callToolErrorResult err

private def handleDropWorkspace
    (state : IO.Ref ProtocolState)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  let input ←
    match fromJson? (α := DropWorkspaceInput) arguments with
    | .ok input => pure input
    | .error err =>
        emitProgress? progress? "lean_drop_workspace failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let currentState ← state.get
  let updateTrackedState : IO Unit :=
    state.modify fun currentState => {
      currentState with
      root? :=
        if input.workspaceId == Beam.Broker.defaultWorkspaceId then
          none
        else
          currentState.root?
      rootError? :=
        if input.workspaceId == Beam.Broker.defaultWorkspaceId then
          some droppedDefaultWorkspaceMessage
        else
          currentState.rootError?
      workspaces := currentState.workspaces.erase input.workspaceId
    }
  match currentState.runtime? with
  | none =>
      updateTrackedState
      emitProgress? progress? "completed lean_drop_workspace"
      pure <| callToolResult <| Json.mkObj [
        ("workspace_id", toJson input.workspaceId),
        ("dropped", toJson false),
        ("reason", toJson ("notFound" : String))
      ]
  | some runtime =>
      let (brokerResp, _) ← runtime.dispatchRequest {
        op := .dropWorkspace
        workspaceId? := some input.workspaceId
      }
      if brokerResp.ok then
        updateTrackedState
        match brokerResp.result? with
        | some payload =>
            emitProgress? progress? "completed lean_drop_workspace"
            pure <| callToolResult payload
        | none =>
            emitProgress? progress? "lean_drop_workspace failed"
            pure <| callToolErrorResult <|
              ToolError.invalidResult "workspace drop succeeded without a result payload"
      else
        emitProgress? progress? "lean_drop_workspace failed"
        let err :=
          match brokerResp.error? with
          | some err => ToolError.fromBrokerError err
          | none => ToolError.runtimeSetup "workspace drop failed without a typed broker error"
        pure <| callToolErrorResult err

private def resolvedBeamHome? : IO (Option System.FilePath) := do
  match ← IO.getEnv "BEAM_HOME" with
  | some home =>
      try
        pure <| some (← IO.FS.realPath <| System.FilePath.mk home)
      catch _ =>
        pure <| some (System.FilePath.mk home)
  | none => pure none

private def serverIdentity
    (opts : Options)
    (activeRoot? : Option System.FilePath := none)
    (runtimeActive? : Option Bool := none) : IO Beam.Version.Identity := do
  let home? ← resolvedBeamHome?
  let appPath ← IO.appPath
  let wrapper? ← IO.getEnv "BEAM_WRAPPER_PATH"
  Beam.Version.mcpServerIdentity
    home?
    opts.beamCli?
    (some appPath.toString)
    activeRoot?
    runtimeActive?
    (wrapper? := wrapper?)

private def serverVersionText (opts : Options) : IO String := do
  pure (← serverIdentity opts).text

private def handleBeamVersion
    (state : IO.Ref ProtocolState)
    (opts : Options) : IO Json := do
  let currentState ← state.get
  let identity ← serverIdentity opts currentState.root? (some currentState.runtime?.isSome)
  pure <| callToolResult identity.asJson

private def collectFeedbackRuntimePayload
    (runtime? : Option Beam.Broker.ServerRuntime)
    (root? : Option System.FilePath)
    (warnings : Array String) : IO (Json × Json × Array String) := do
  match runtime? with
  | none =>
      pure (Json.null, Json.null, warnings.push "no active MCP Lean runtime was available for stats/open-files")
  | some runtime =>
      let (statsResp, _) ← runtime.dispatchRequest { op := .stats }
      let (stats, warnings) := Beam.Feedback.responsePayloadOrWarning "stats" statsResp warnings
      let (openResp, _) ← runtime.dispatchRequest { op := .openDocs, root? := root?.map (·.toString) }
      let (openDocs, warnings) := Beam.Feedback.responsePayloadOrWarning "open-files" openResp warnings
      pure (stats, openDocs, warnings)

private def feedbackAllowedRoots
    (root? : Option System.FilePath) : IO (Array System.FilePath) := do
  match root? with
  | some root => do
      let control ← Beam.Daemon.controlDir root
      pure #[root, control]
  | none => pure #[]

private def feedbackIncludeCollected (arguments : Json) : Except String Bool := do
  match arguments.getObjVal? "include_collected" with
  | .ok value =>
      match fromJson? (α := Bool) value with
      | .ok includeCollected => pure includeCollected
      | .error err => throw s!"invalid 'include_collected': {err}"
  | .error _ => pure false

private def handleBeamFeedback
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  let input ←
    match fromJson? (α := Beam.Feedback.Input) arguments with
    | .ok input => pure input
    | .error err =>
        emitProgress? progress? "beam_feedback failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let includeCollected ←
    match feedbackIncludeCollected arguments with
    | .ok includeCollected => pure includeCollected
    | .error err =>
        emitProgress? progress? "beam_feedback failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let currentState ← state.get
  emitProgress? progress? "collecting beam_feedback context"
  let generatedAt ← Beam.utcTimestamp
  let identity ← serverIdentity opts currentState.root? (some currentState.runtime?.isSome)
  let mut warnings := #[]
  let daemon ←
    match currentState.root? with
    | some root => Beam.Daemon.daemonDebugContextJson root
    | none =>
        warnings := warnings.push "no known MCP root was available for daemon registry context"
        pure Json.null
  let warningsWithDaemon := warnings ++ Beam.Daemon.daemonDebugWarnings daemon
  let (stats, openDocs, warnings') ←
    collectFeedbackRuntimePayload currentState.runtime? currentState.root? warningsWithDaemon
  let collection : Beam.Feedback.Collection := {
    generatedAt
    activeRoot? := currentState.root?.map (·.toString)
    data := Json.mkObj [
      ("identity", identity.asJson),
      ("stats", stats),
      ("openFiles", openDocs),
      ("daemon", daemon)
    ]
    warnings := warnings'
  }
  let allowedRoots ← feedbackAllowedRoots currentState.root?
  try
    let result ← Beam.Feedback.buildResult input collection {
      root? := currentState.root?
      allowedRoots
    }
    let markdown ← Beam.Feedback.renderMcpMarkdown input collection includeCollected
    emitProgress? progress? "completed beam_feedback"
    pure <| callToolResult <| Beam.Feedback.resultMcpJson result markdown includeCollected
  catch e =>
    emitProgress? progress? "beam_feedback failed"
    pure <| callToolErrorResult <| ToolError.invalidInput e.toString

private def brokerRequestForTool
    (root : System.FilePath)
    (params : CallToolParams)
    (clientRequestId : String) : Except String Beam.Broker.Request := do
  let req ← params.name.toBrokerRequest root.toString params.arguments
  pure { req with clientRequestId? := some clientRequestId }

private def toolWorkspaceId (arguments : Json) : Except String Beam.Broker.WorkspaceId := do
  match arguments.getObjVal? "workspace_id" with
  | .ok value =>
      match fromJson? (α := Beam.Broker.WorkspaceId) value with
      | .ok workspaceId =>
          if workspaceId.isEmpty then
            throw "workspace_id must be non-empty"
          else
            pure workspaceId
      | .error err => throw s!"invalid 'workspace_id': {err}"
  | .error _ =>
      pure Beam.Broker.defaultWorkspaceId

private def handleToolCall
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request)
    (notifications : NotificationSink) : IO (Except RpcError Json) := do
  let notifier : Notifier := { state, sink := notifications }
  let params ←
    match parseCallToolParams req.params? with
    | .ok params => pure params
    | .error err => return .error <| RpcError.invalidParams err
  let progress? ← ProgressEmitter.create? params.progressToken? notifier.send
  traceMcp
    s!"tools/call start id={requestIdLabel req.id} tool={params.name.key} progressToken={params.progressToken?.isSome}"
  if params.name == .leanInitWorkspace then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleInitWorkspace state opts params.arguments progress?
    traceMcp s!"tools/call init complete id={requestIdLabel req.id} tool={params.name.key}"
    return .ok result
  if params.name == .leanListWorkspaces then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleListWorkspaces state params.arguments progress?
    traceMcp s!"tools/call workspace list complete id={requestIdLabel req.id} tool={params.name.key}"
    return .ok result
  if params.name == .leanDropWorkspace then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleDropWorkspace state params.arguments progress?
    traceMcp s!"tools/call workspace drop complete id={requestIdLabel req.id} tool={params.name.key}"
    return .ok result
  if params.name == .beamVersion then
    let result ← handleBeamVersion state opts
    traceMcp s!"tools/call version complete id={requestIdLabel req.id} tool={params.name.key}"
    return .ok result
  if params.name == .beamFeedback then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleBeamFeedback state opts params.arguments progress?
    traceMcp s!"tools/call feedback complete id={requestIdLabel req.id} tool={params.name.key}"
    return .ok result
  let workspaceId ←
    match toolWorkspaceId params.arguments with
    | .ok workspaceId => pure workspaceId
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let root ←
    if workspaceId == Beam.Broker.defaultWorkspaceId then
      match ← ensureRoot state stdin notifier with
      | .ok root =>
          traceMcp s!"tools/call root ready id={requestIdLabel req.id} root={root}"
          pure root
      | .error err =>
          emitProgress? progress? s!"failed {params.name.key}"
          traceMcp s!"tools/call root failed id={requestIdLabel req.id} tool={params.name.key}"
          return .error err
    else
      let currentState ← state.get
      match currentState.workspaces.get? workspaceId with
      | some root =>
          traceMcp
            s!"tools/call workspace ready id={requestIdLabel req.id} workspace={workspaceId} root={root}"
          pure root
      | none =>
          emitProgress? progress? s!"failed {params.name.key}"
          return .ok <| callToolErrorResult <| ToolError.invalidInput
            s!"unknown Beam workspace '{workspaceId}'; call lean_init_workspace with workspace_id first"
  emitProgress? progress? s!"starting {params.name.key}"
  emitProgress? progress? s!"preparing {params.name.key}"
  let brokerReq ←
    match brokerRequestForTool root params (brokerClientRequestId req) with
    | .ok brokerReq => pure brokerReq
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        traceMcp s!"tools/call invalid input id={requestIdLabel req.id} tool={params.name.key} error={err}"
        return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let (runtime, _root) ←
    match ← ensureRuntimeForWorkspace state opts stdin notifier workspaceId root with
    | .ok runtimeAndRoot =>
        traceMcp s!"tools/call runtime ready id={requestIdLabel req.id} tool={params.name.key}"
        pure runtimeAndRoot
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        traceMcp s!"tools/call runtime failed id={requestIdLabel req.id} tool={params.name.key}"
        return .error err
  let emitDiagnostic : Beam.Broker.StreamDiagnostic → IO Unit := fun diagnostic =>
    emitDiagnosticLog notifier diagnostic
  let emitBrokerProgress? : Option (Beam.Broker.SyncFileProgress → IO Unit) :=
    progress?.map fun progress => fun fileProgress =>
      progress.emitFileProgress params.name fileProgress
  emitProgress? progress? s!"running {params.name.key}"
  traceMcp s!"tools/call dispatch broker id={requestIdLabel req.id} tool={params.name.key}"
  let (brokerResp, _) ← runtime.dispatchRequest brokerReq
    (emitProgress? := emitBrokerProgress?)
    (emitDiagnostic? := some emitDiagnostic)
  traceMcp
    s!"tools/call broker returned id={requestIdLabel req.id} tool={params.name.key} ok={brokerResp.ok}"
  match normalizeBrokerResponse params.name brokerResp with
  | .ok result =>
      traceMcp s!"tools/call response ready id={requestIdLabel req.id} tool={params.name.key}"
      let result := Beam.Workspace.addActiveRoot root result
      let result := result.setObjVal! "workspace_id" (toJson workspaceId)
      pure <| .ok <| callToolResult result
  | .error err =>
      traceMcp s!"tools/call tool error id={requestIdLabel req.id} tool={params.name.key}"
      pure <| .ok <| callToolErrorResult err

private def handleReadyOperationRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request)
    (notifications : NotificationSink) : IO (Json × Bool) := do
  match req.method with
  | "tools/list" =>
      pure (successResponse req.id toolsListResult, false)
  | "tools/call" =>
      match ← handleToolCall state opts stdin req notifications with
      | .ok result => pure (successResponse req.id result, false)
      | .error err => pure (errorResponse req.id err, false)
  | method =>
      pure (errorResponse req.id (RpcError.methodNotFound method), false)

private def handleSetLogLevel
    (state : IO.Ref ProtocolState)
    (req : Request) : IO (Json × Bool) := do
  match parseSetLogLevelParams req.params? with
  | .ok level =>
      state.modify fun currentState => { currentState with logLevel := level }
      pure (successResponse req.id (Json.mkObj []), false)
  | .error err =>
      pure (errorResponse req.id (RpcError.invalidParams err), false)

def handleRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request)
    (notifications : NotificationSink := {}) : IO (Json × Bool) := do
  let currentState ← state.get
  match req.method with
  | "initialize" =>
      if currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize has already completed"), false)
      else
        state.set {
          currentState with
            initializeComplete := true
            clientSupportsRoots := clientSupportsRoots req.params?
        }
        pure (successResponse req.id initializeResult, false)
  | "ping" =>
      pure (successResponse req.id (Json.mkObj []), false)
  | "logging/setLevel" =>
      if !currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize must complete before MCP logging requests"), false)
      else
        handleSetLogLevel state req
  | "shutdown" =>
      match currentState.runtime? with
      | none =>
          pure (successResponse req.id (Json.mkObj []), true)
      | some runtime =>
          let (brokerResp, _) ← runtime.dispatchRequest { op := .shutdown }
          if brokerResp.ok then
            pure (successResponse req.id (Json.mkObj []), true)
          else
            let message := (brokerResp.error?.map (·.message)).getD "Beam broker shutdown failed"
            pure (errorResponse req.id (RpcError.internalError message), false)
  | "tools/list" | "tools/call" =>
      if !currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize must complete before MCP operation requests"), false)
      else if !currentState.initializedNotificationSeen then
        pure (errorResponse req.id (RpcError.invalidRequest "notifications/initialized is required before MCP operation requests"), false)
      else
        handleReadyOperationRequest state opts stdin req notifications
  | method =>
      if !currentState.initializeComplete then
        pure (errorResponse req.id (RpcError.invalidRequest "initialize must be the first MCP operation"), false)
      else
        pure (errorResponse req.id (RpcError.methodNotFound method), false)

def handleNotification
    (state : IO.Ref ProtocolState)
    (notification : Notification) : IO Bool := do
  match notification.method with
  | "notifications/initialized" =>
      let currentState ← state.get
      if currentState.initializeComplete then
        state.set { currentState with initializedNotificationSeen := true }
      pure false
  | "exit" => pure true
  | _ => pure false

def handleJson
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (json : Json)
    (notifications : NotificationSink := {}) : IO (Option Json × Bool) := do
  match Incoming.fromJson? json with
  | .ok (.request req) =>
      let (resp, stop) ← handleRequest state opts stdin req notifications
      pure (some resp, stop)
  | .ok (.notification notification) =>
      let stop ← handleNotification state notification
      pure (none, stop)
  | .error err =>
      pure (some <| errorResponse (invalidRequestId json) (RpcError.invalidRequest err), false)

partial def runStdio (opts : Options) (root? : Option System.FilePath) : IO Unit := do
  let stdin ← IO.getStdin
  let state ← ProtocolState.create root?
  let rec loop : IO Unit := do
    let line := Beam.Mcp.Stdio.stripLineEnding (← stdin.getLine)
    if line.isEmpty then
      pure ()
    else
      match Json.parse line with
      | .error err =>
          writeJsonLine <| errorResponse Json.null (RpcError.parseError err)
          loop
      | .ok json =>
          let (response?, stop) ← handleJson state opts stdin json { send := writeJsonLine }
          match response? with
          | some response => writeJsonLine response
          | none => pure ()
          unless stop do
            loop
  try
    loop
  catch e =>
    if Beam.Mcp.Stdio.isBrokenPipeError e then
      pure ()
    else
      throw e

private def requireStartupRoot (rootText : String) : IO System.FilePath := do
  match ← Beam.Lean.Workspace.resolveCliRoot rootText with
  | .ok root => pure root
  | .error err => throw <| IO.userError err.message

def main (args : List String) : IO Unit := do
  let opts ←
    match Beam.Mcp.parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  if opts.showVersion then
    IO.println (← serverVersionText opts)
    return
  match opts.selfCheckPath? with
  | some path =>
      SelfCheck.run {
        root? := opts.root?
        leanCmd? := opts.leanCmd?
        leanPlugin? := opts.leanPlugin?
        beamCli? := opts.beamCli?
      } path
  | none =>
      let root? ← opts.root?.mapM requireStartupRoot
      runStdio opts root?

end Beam.Mcp.Server
