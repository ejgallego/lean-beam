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
import Beam.System
import Beam.Workspace
import Beam.Version

open Lean

/-!
Typed MCP request handling independent of the stdio transport.

`Beam.Mcp.StdioServer` owns concurrent request coordination, cancellation, lifecycle barriers, and
transport I/O. The declarations under `Internal` are the narrow bridge used by that coordinator.
-/

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

private def ProtocolState.trackWorkspace
    (state : ProtocolState)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) : ProtocolState := {
  state with
  root? :=
    if workspaceId == Beam.Broker.defaultWorkspaceId then
      some root
    else
      state.root?
  rootError? :=
    if workspaceId == Beam.Broker.defaultWorkspaceId then
      none
    else
      state.rootError?
  workspaces := state.workspaces.insert workspaceId root
}

structure NotificationSink where
  send : Json → IO Unit := fun _ => pure ()

private structure Notifier where
  state : IO.Ref ProtocolState
  sink : NotificationSink

private def Notifier.send (notifier : Notifier) (json : Json) : IO Unit :=
  notifier.sink.send json

abbrev Options := Beam.Mcp.Options

def Internal.traceEnabled (envName : String) : IO Bool := do
  match ← IO.getEnv envName with
  | some value => pure (!value.isEmpty && value != "0")
  | none => pure false

def Internal.traceMcp (message : String) : IO Unit := do
  if ← Internal.traceEnabled "LEAN_BEAM_MCP_TRACE" then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: {message}"

private structure ProgressState where
  nextProgress : Nat := 0
  lastFileProgress : Option Beam.Broker.SyncFileProgress := none

private structure ProgressEmitter where
  progressToken : Json
  state : Std.Mutex ProgressState
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
        state := ← Std.Mutex.new {}
        emitNotification
      }

private def ProgressEmitter.emit
    (emitter : ProgressEmitter)
    (message : String)
    (total? : Option Nat := none) : IO Unit := do
  emitter.state.atomically do
    let current ← get
    let next := current.nextProgress + 1
    set { current with nextProgress := next }
    emitter.emitNotification <| progressNotification emitter.progressToken next (some message) total?

private def ProgressEmitter.emitFileProgress
    (emitter : ProgressEmitter)
    (tool : ToolName)
    (fileProgress : Beam.Broker.SyncFileProgress) : IO Unit := do
  emitter.state.atomically do
    let current ← get
    if shouldEmitFileProgress current.lastFileProgress fileProgress then
      let next := current.nextProgress + 1
      set { current with
        nextProgress := next
        lastFileProgress := some fileProgress
      }
      emitter.emitNotification <|
        progressNotification emitter.progressToken next (some <| fileProgressMessage tool fileProgress)

private def emitProgress?
    (progress? : Option ProgressEmitter)
    (message : String)
    (total? : Option Nat := none) : IO Unit := do
  match progress? with
  | some progress => progress.emit message total?
  | none => pure ()

def Internal.invalidRequestId (json : Json) : Json :=
  match json.getObjVal? "id" with
  | .ok id =>
      if (RequestId.fromJson? id).isOk then id else Json.null
  | .error _ => Json.null

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

private def createRuntimeWithConfig
    (workspaceId : Beam.Broker.WorkspaceId)
    (config : Beam.Broker.BrokerConfig) :
    IO (Except RpcError Beam.Broker.ServerRuntime) := do
  try
    pure <| .ok (← Beam.Broker.ServerRuntime.create config workspaceId)
  catch e =>
    pure <| .error <| runtimeSetupError e.toString

private def createRuntimeForRoot
    (opts : Options)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) :
    IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  match ← Runtime.mkBrokerConfig (runtimeOptions opts) root with
  | .error err =>
      pure <| .error err
  | .ok config =>
      match ← createRuntimeWithConfig workspaceId config with
      | .ok runtime => pure <| .ok (runtime, config.root)
      | .error err => pure <| .error err

private def ensureRoot
    (state : IO.Ref ProtocolState)
    (requestRoot : IO (Except String System.FilePath)) : IO (Except RpcError System.FilePath) := do
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
              requestRoot
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
          let brokerResp ← runtime.initWorkspaceWithConfig workspaceId config (some .set)
          if brokerResp.ok then
            state.modify fun state => state.trackWorkspace workspaceId config.root
            pure <| .ok config.root
          else
            let message := (brokerResp.error?.map (·.message)).getD
              s!"failed to initialize workspace '{workspaceId}'"
            pure <| .error <| RpcError.invalidRequest message

private def ensureRuntime
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (requestRoot : IO (Except String System.FilePath)) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  setupMutex.atomically do
    let currentState ← state.get
    match currentState.runtime?, currentState.root? with
    | some runtime, some root =>
        match ← ensureBrokerWorkspace state opts runtime Beam.Broker.defaultWorkspaceId root with
        | .ok root => pure <| .ok (runtime, root)
        | .error err => pure <| .error err
    | _, _ =>
        match ← ensureRoot state requestRoot with
        | .error err => pure <| .error err
        | .ok root =>
            match ← createRuntimeForRoot opts Beam.Broker.defaultWorkspaceId root with
            | .error err =>
                state.modify fun state => { state with rootError? := some err.message }
                pure <| .error err
            | .ok (runtime, root) =>
                state.modify fun state => {
                  state.trackWorkspace Beam.Broker.defaultWorkspaceId root with
                  runtime? := some runtime
                }
                pure <| .ok (runtime, root)

private def ensureRuntimeForWorkspace
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (requestRoot : IO (Except String System.FilePath))
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  if workspaceId == Beam.Broker.defaultWorkspaceId then
    ensureRuntime state opts setupMutex requestRoot
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

private def toolErrorOfBrokerResponse
    (resp : Beam.Broker.Response)
    (fallback : String) : ToolError :=
  match resp.error? with
  | some err => ToolError.fromBrokerError err
  | none => ToolError.runtimeSetup fallback

private def handleInitWorkspace
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := setupMutex.atomically do
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
  let workspaceId := input.workspaceId
  let currentState ← state.get
  let config ←
    match ← Runtime.mkBrokerConfig (runtimeOptions opts) requestedRoot with
    | .error err =>
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| ToolError.runtimeSetup err.message
    | .ok config => pure config
  let finalizeSuccess (payload : Json) (root : System.FilePath) : IO Json := do
    state.modify fun currentState => currentState.trackWorkspace workspaceId root
    emitProgress? progress? "completed lean_init_workspace"
    pure <| callToolResult <| withCapabilities payload
  match currentState.runtime? with
  | none =>
      if mode == .verify then
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| ToolError.invalidInput
          s!"workspace '{workspaceId}' is not initialized; use mode=set first"
      emitProgress? progress? "starting workspace runtime"
      match ← createRuntimeWithConfig workspaceId config with
      | .error err =>
          emitProgress? progress? "lean_init_workspace failed"
          return callToolErrorResult <| ToolError.runtimeSetup err.message
      | .ok runtime =>
          state.modify fun currentState => { currentState with runtime? := some runtime }
          finalizeSuccess
            (toJson <| Beam.Broker.workspaceInitResult workspaceId config.root mode false false)
            config.root
  | some runtime =>
      emitProgress? progress? "initializing workspace runtime"
      let brokerResp ← runtime.initWorkspaceWithConfig workspaceId config (some mode)
      if brokerResp.ok then
        match brokerResp.result? with
        | some payload => finalizeSuccess payload config.root
        | none =>
            emitProgress? progress? "lean_init_workspace failed"
            return callToolErrorResult <| ToolError.invalidResult
              "workspace initialization succeeded without a result payload"
      else
        emitProgress? progress? "lean_init_workspace failed"
        return callToolErrorResult <| toolErrorOfBrokerResponse brokerResp
          "workspace initialization failed without a typed broker error"

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
        let err := toolErrorOfBrokerResponse brokerResp
          "workspace listing failed without a typed broker error"
        pure <| callToolErrorResult err

private def handleBeamStats
    (state : IO.Ref ProtocolState)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  match requireEmptyInput "beam_stats" arguments with
  | .error err =>
      emitProgress? progress? "beam_stats failed"
      return callToolErrorResult <| ToolError.invalidInput err
  | .ok () => pure ()
  let runtime ←
    match (← state.get).runtime? with
    | some runtime => pure runtime
    | none =>
        emitProgress? progress? "completed beam_stats"
        return callToolResult <| Json.mkObj [("workspaces", Json.mkObj [])]
  let (brokerResp, _) ← runtime.dispatchRequest { op := .stats }
  match normalizeBrokerResponse .beamStats brokerResp with
  | .error err =>
      emitProgress? progress? "beam_stats failed"
      pure <| callToolErrorResult err
  | .ok result =>
      let uptimeMs :=
        match result.getObjVal? "uptimeMs" with
        | .ok uptimeMs => uptimeMs
        | .error _ => Json.null
      let workspaces :=
        match result.getObjVal? "workspaces" with
        | .ok workspaces => workspaces
        | .error _ => Json.mkObj []
      let result := Json.mkObj [
        ("uptimeMs", uptimeMs),
        ("workspaces", workspaces)
      ]
      emitProgress? progress? "completed beam_stats"
      pure <| callToolResult result

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
        let err := toolErrorOfBrokerResponse brokerResp
          "workspace drop failed without a typed broker error"
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

def Internal.serverVersionText (opts : Options) : IO String := do
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
    (opts : Options)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath)
    (runtime? : Option Beam.Broker.ServerRuntime)
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
  emitProgress? progress? "collecting beam_feedback context"
  let generatedAt ← Beam.utcTimestamp
  let identity ← serverIdentity opts (some root) (some runtime?.isSome)
  let mut warnings := #[]
  let daemon ← Beam.Daemon.daemonDebugContextJson root
  let warningsWithDaemon := warnings ++ Beam.Daemon.daemonDebugWarnings daemon
  let (stats, openDocs, warnings') ←
    collectFeedbackRuntimePayload runtime? (some root) warningsWithDaemon
  let collection : Beam.Feedback.Collection := {
    generatedAt
    activeRoot? := some root.toString
    data := Json.mkObj [
      ("identity", identity.asJson),
      ("stats", stats),
      ("openFiles", openDocs),
      ("daemon", daemon)
    ]
    warnings := warnings'
  }
  let allowedRoots ← feedbackAllowedRoots (some root)
  try
    let result ← Beam.Feedback.buildResult input collection {
      root? := some root
      allowedRoots
    }
    let markdown ← Beam.Feedback.renderMcpMarkdown input collection includeCollected
    emitProgress? progress? "completed beam_feedback"
    let result := (Beam.Feedback.resultMcpJson result markdown includeCollected).setObjVal!
      "workspace_id" (toJson workspaceId)
    pure <| callToolResult result
  catch e =>
    emitProgress? progress? "beam_feedback failed"
    pure <| callToolErrorResult <| ToolError.invalidInput e.toString

private def brokerRequestForTool
    (root : System.FilePath)
    (params : CallToolParams)
    (clientRequestId : String) : Except String Beam.Broker.Request := do
  let req ← params.name.toBrokerRequest root.toString params.arguments
  pure { req with clientRequestId? := some clientRequestId }

private def toolWorkspaceId
    (arguments : Json) : Except String Beam.Broker.WorkspaceId := do
  let value ←
    match arguments.getObjVal? "workspace_id" with
    | .ok value => pure value
    | .error _ => throw "workspace_id is required"
  let workspaceId ←
    match fromJson? (α := Beam.Broker.WorkspaceId) value with
    | .ok workspaceId => pure workspaceId
    | .error err => throw s!"invalid 'workspace_id': {err}"
  unless Beam.Workspace.validWorkspaceId workspaceId do
    throw "workspace_id must be non-empty"
  pure workspaceId

def Internal.handleToolCall
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (requestRoot : IO (Except String System.FilePath))
    (brokerClientRequestId : String)
    (beforeDispatch : Beam.Broker.ServerRuntime → System.FilePath → IO Bool)
    (req : Request)
    (parsedParams : Except String CallToolParams)
    (notifications : NotificationSink) : IO (Except RpcError Json) := do
  let notifier : Notifier := { state, sink := notifications }
  let params ←
    match parsedParams with
    | .ok params => pure params
    | .error err => return .error <| RpcError.invalidParams err
  let progress? ← ProgressEmitter.create? params.progressToken? notifier.send
  Internal.traceMcp
    s!"tools/call start id={req.id.label} tool={params.name.key} progressToken={params.progressToken?.isSome}"
  if params.name == .leanInitWorkspace then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleInitWorkspace state opts setupMutex params.arguments progress?
    Internal.traceMcp s!"tools/call init complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .leanListWorkspaces then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleListWorkspaces state params.arguments progress?
    Internal.traceMcp s!"tools/call workspace list complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .leanDropWorkspace then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleDropWorkspace state params.arguments progress?
    Internal.traceMcp s!"tools/call workspace drop complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .beamVersion then
    let result ← handleBeamVersion state opts
    Internal.traceMcp s!"tools/call version complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .beamStats then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleBeamStats state params.arguments progress?
    Internal.traceMcp s!"tools/call stats complete id={req.id.label} tool={params.name.key}"
    return .ok result
  let workspaceId ←
    match toolWorkspaceId params.arguments with
    | .ok workspaceId => pure workspaceId
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let root ←
    if workspaceId == Beam.Broker.defaultWorkspaceId then
      match ← setupMutex.atomically do ensureRoot state requestRoot with
      | .ok root =>
          Internal.traceMcp s!"tools/call root ready id={req.id.label} root={root}"
          pure root
      | .error err =>
          emitProgress? progress? s!"failed {params.name.key}"
          Internal.traceMcp s!"tools/call root failed id={req.id.label} tool={params.name.key}"
          return .error err
    else
      let currentState ← state.get
      match currentState.workspaces.get? workspaceId with
      | some root =>
          Internal.traceMcp
            s!"tools/call workspace ready id={req.id.label} workspace={workspaceId} root={root}"
          pure root
      | none =>
          emitProgress? progress? s!"failed {params.name.key}"
          return .ok <| callToolErrorResult <| ToolError.invalidInput
            s!"unknown Beam workspace '{workspaceId}'; call lean_init_workspace with workspace_id first"
  if params.name == .beamFeedback then
    emitProgress? progress? s!"starting {params.name.key}"
    let currentState ← state.get
    let result ← handleBeamFeedback opts workspaceId root currentState.runtime? params.arguments progress?
    Internal.traceMcp s!"tools/call feedback complete id={req.id.label} tool={params.name.key}"
    return .ok result
  emitProgress? progress? s!"starting {params.name.key}"
  emitProgress? progress? s!"preparing {params.name.key}"
  let brokerReq ←
    match brokerRequestForTool root params brokerClientRequestId with
    | .ok brokerReq => pure brokerReq
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        Internal.traceMcp s!"tools/call invalid input id={req.id.label} tool={params.name.key} error={err}"
        return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let (runtime, _root) ←
    match ← ensureRuntimeForWorkspace state opts setupMutex requestRoot workspaceId root with
    | .ok runtimeAndRoot =>
        Internal.traceMcp s!"tools/call runtime ready id={req.id.label} tool={params.name.key}"
        pure runtimeAndRoot
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        Internal.traceMcp s!"tools/call runtime failed id={req.id.label} tool={params.name.key}"
        return .error err
  unless ← beforeDispatch runtime root do
    return .error <| RpcError.invalidRequest "request was cancelled before broker dispatch"
  let emitDiagnostic : Beam.Broker.StreamDiagnostic → IO Unit := fun diagnostic =>
    emitDiagnosticLog notifier diagnostic
  let emitBrokerProgress? : Option (Beam.Broker.SyncFileProgress → IO Unit) :=
    progress?.map fun progress => fun fileProgress =>
      progress.emitFileProgress params.name fileProgress
  emitProgress? progress? s!"running {params.name.key}"
  Internal.traceMcp s!"tools/call dispatch broker id={req.id.label} tool={params.name.key}"
  let (brokerResp, _) ← runtime.dispatchRequest brokerReq
    (emitProgress? := emitBrokerProgress?)
    (emitDiagnostic? := some emitDiagnostic)
  Internal.traceMcp
    s!"tools/call broker returned id={req.id.label} tool={params.name.key} ok={brokerResp.ok}"
  match normalizeBrokerResponse params.name brokerResp with
  | .ok result =>
      Internal.traceMcp s!"tools/call response ready id={req.id.label} tool={params.name.key}"
      let result := Beam.Workspace.addActiveRoot root result
      let result := result.setObjVal! "workspace_id" (toJson workspaceId)
      pure <| .ok <| callToolResult result
  | .error err =>
      Internal.traceMcp s!"tools/call tool error id={req.id.label} tool={params.name.key}"
      pure <| .ok <| callToolErrorResult err

private def handleReadyOperationRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (requestRoot : IO (Except String System.FilePath))
    (brokerClientRequestId : String)
    (req : Request)
    (notifications : NotificationSink) : IO (Json × Bool) := do
  match req.method with
  | "tools/list" =>
      pure (successResponse req.id toolsListResult, false)
  | "tools/call" =>
      let parsedParams := parseCallToolParams req.params?
      match ← Internal.handleToolCall state opts setupMutex requestRoot brokerClientRequestId
          (fun _ _ => pure true) req parsedParams notifications with
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
    (req : Request)
    (notifications : NotificationSink := {}) : IO (Json × Bool) := do
  let setupMutex ← Std.Mutex.new ()
  let requestRoot : IO (Except String System.FilePath) :=
    pure <| .error Roots.unsupportedMessage
  let brokerClientRequestId := s!"mcp:sync:{req.id.label}"
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
        handleReadyOperationRequest
          state opts setupMutex requestRoot brokerClientRequestId req notifications
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
    (json : Json)
    (notifications : NotificationSink := {}) : IO (Option Json × Bool) := do
  match Incoming.fromJson? json with
  | .ok (.request req) =>
      let (resp, stop) ← handleRequest state opts req notifications
      pure (some resp, stop)
  | .ok (.notification notification) =>
      let stop ← handleNotification state notification
      pure (none, stop)
  | .ok (.response _) =>
      pure (none, false)
  | .error err =>
      pure (some <| errorResponse (Internal.invalidRequestId json) (RpcError.invalidRequest err), false)

end Beam.Mcp.Server
