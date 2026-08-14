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

inductive LegacyProtocolPhase where
  | awaitingInitialized
  | ready
  deriving BEq, Repr

structure LegacyProtocolState where
  phase : LegacyProtocolPhase := .awaitingInitialized
  logLevel : LogLevel := .debug
  deriving Repr

inductive ProtocolState where
  | undecided
  | legacy (state : LegacyProtocolState)
  | modern
  deriving Repr

structure ApplicationState where
  workspaces : Std.TreeMap Beam.Broker.WorkspaceId System.FilePath := {}
  runtime? : Option Beam.Broker.ServerRuntime := none

structure ServerState where
  protocol : Std.Mutex ProtocolState
  application : IO.Ref ApplicationState

def ServerState.create : IO ServerState := do
  pure {
    protocol := ← Std.Mutex.new .undecided
    application := ← IO.mkRef {}
  }

def ServerState.protocolState (state : ServerState) : IO ProtocolState :=
  state.protocol.atomically get

def ServerState.applicationState (state : ServerState) : IO ApplicationState :=
  state.application.get

private def ApplicationState.trackWorkspace
    (state : ApplicationState)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) : ApplicationState := {
  state with
  workspaces := state.workspaces.insert workspaceId root
}

structure NotificationSink where
  send : Json → IO Unit := fun _ => pure ()

private inductive DiagnosticLogPolicy where
  | legacy (state : ServerState)
  | request (minimum? : Option LogLevel)

private structure Notifier where
  logPolicy : DiagnosticLogPolicy
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
  let minimum? ←
    match notifier.logPolicy with
    | .legacy state =>
        match ← state.protocolState with
        | .legacy legacy => pure <| some legacy.logLevel
        | .undecided | .modern => pure none
    | .request minimum? => pure minimum?
  match minimum? with
  | some minimum =>
      if minimum.allows level then
        notifier.send <|
          logMessageNotification level "lean.diagnostic" (streamDiagnosticLogData diagnostic)
  | none => pure ()

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

private def ensureBrokerWorkspace
    (state : ServerState)
    (opts : Options)
    (runtime : Beam.Broker.ServerRuntime)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) : IO (Except RpcError System.FilePath) := do
  let application ← state.applicationState
  match application.workspaces.get? workspaceId with
  | some trackedRoot =>
      if trackedRoot == root then
        pure <| .ok root
      else
        pure <| .error <| RpcError.invalidRequest
          s!"workspace '{workspaceId}' is already initialized for {trackedRoot}, not {root}"
  | none =>
      match ← Runtime.mkBrokerConfig (runtimeOptions opts) root with
      | .error err => pure <| .error err
      | .ok config =>
          let brokerResp ← runtime.initWorkspaceWithConfig workspaceId config (some .set)
          if brokerResp.ok then
            state.application.modify fun application =>
              application.trackWorkspace workspaceId config.root
            pure <| .ok config.root
          else
            let message := (brokerResp.error?.map (·.message)).getD
              s!"failed to initialize workspace '{workspaceId}'"
            pure <| .error <| RpcError.invalidRequest message

private def ensureRuntimeForWorkspace
    (state : ServerState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  setupMutex.atomically do
    let application ← state.applicationState
    match application.runtime? with
    | some runtime =>
        match ← ensureBrokerWorkspace state opts runtime workspaceId root with
        | .ok canonicalRoot => pure <| .ok (runtime, canonicalRoot)
        | .error err => pure <| .error err
    | none =>
        match ← createRuntimeForRoot opts workspaceId root with
        | .error err => pure <| .error err
        | .ok (runtime, canonicalRoot) =>
            state.application.modify fun application => {
              application.trackWorkspace workspaceId canonicalRoot with
              runtime? := some runtime
            }
            pure <| .ok (runtime, canonicalRoot)

private def workspaceErrorToToolError (err : Beam.Workspace.RootError) : ToolError :=
  ToolError.invalidInput err.message

private structure ResolvedWorkspace where
  descriptor : Beam.Workspace.Descriptor
  root : System.FilePath
  workspaceId : Beam.Broker.WorkspaceId

private def resolveWorkspace (arguments : Json) : IO (Except ToolError ResolvedWorkspace) := do
  let descriptor ←
    match Beam.Workspace.decodeDescriptorField arguments with
    | .ok descriptor => pure descriptor
    | .error err => return .error <| ToolError.invalidInput err
  match ← Beam.Lean.Workspace.resolveRoot descriptor.root with
  | .error err => pure <| .error <| workspaceErrorToToolError err
  | .ok root =>
      let descriptor := Beam.Workspace.Descriptor.ofRoot root
      pure <| .ok { descriptor, root, workspaceId := descriptor.cacheKey }

/--
Resolve a workspace descriptor for cache eviction without requiring the project to remain usable.

Existing paths are canonicalized even after their Lean project markers disappear. Missing paths
fall back to lexical normalization, so the canonical descriptor echoed by an earlier successful
request remains sufficient to evict or idempotently re-evict its cache.
-/
private def resolveWorkspaceForDrop
    (arguments : Json) : IO (Except ToolError ResolvedWorkspace) := do
  let descriptor ←
    match Beam.Workspace.decodeDescriptorField arguments with
    | .ok descriptor => pure descriptor
    | .error err => return .error <| ToolError.invalidInput err
  let rootPath := System.FilePath.mk descriptor.root
  if !rootPath.isAbsolute then
    return .error <| ToolError.invalidInput "workspace root must be an absolute path"
  let root ←
    try
      Beam.resolveExistingPath rootPath
    catch _ =>
      pure rootPath.normalize
  let descriptor := Beam.Workspace.Descriptor.ofRoot root
  pure <| .ok { descriptor, root, workspaceId := descriptor.cacheKey }

private def toolErrorOfBrokerResponse
    (resp : Beam.Broker.Response)
    (fallback : String) : ToolError :=
  match resp.error? with
  | some err => ToolError.fromBrokerError err
  | none => ToolError.runtimeSetup fallback

private structure BeamStatsResult where
  uptimeMs : Nat
  workspaces : Json

private def decodeBeamStatsResult (json : Json) : Except String BeamStatsResult := do
  let uptimeMs ← json.getObjValAs? Nat "uptimeMs"
  let workspaces ← json.getObjVal? "workspaces"
  match workspaces with
  | .obj _ => pure { uptimeMs, workspaces }
  | other => throw s!"'workspaces' must be an object, got {other.compress}"

private def handleBeamStats
    (state : ServerState)
    (progress? : Option ProgressEmitter) : IO Json := do
  let runtime ←
    match (← state.applicationState).runtime? with
    | some runtime => pure runtime
    | none =>
        emitProgress? progress? "completed beam_stats"
        return callToolResult <| Json.mkObj [
          ("uptimeMs", toJson (0 : Nat)),
          ("workspaces", Json.mkObj [])
        ]
  let (brokerResp, _) ← runtime.dispatchRequest { op := .stats }
  match normalizeBrokerResponse .beamStats brokerResp with
  | .error err =>
      emitProgress? progress? "beam_stats failed"
      pure <| callToolErrorResult err
  | .ok result =>
      match decodeBeamStatsResult result with
      | .error err =>
          emitProgress? progress? "beam_stats failed"
          pure <| callToolErrorResult <| ToolError.invalidResult
            s!"invalid broker stats result: {err}"
      | .ok stats =>
          let result := Json.mkObj [
            ("uptimeMs", toJson stats.uptimeMs),
            ("workspaces", stats.workspaces)
          ]
          emitProgress? progress? "completed beam_stats"
          pure <| callToolResult result

private def handleDropWorkspace
    (state : ServerState)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  let workspace ←
    match ← resolveWorkspaceForDrop arguments with
    | .ok workspace => pure workspace
    | .error err =>
        emitProgress? progress? "lean_drop_workspace failed"
        return callToolErrorResult err
  let application ← state.applicationState
  let updateTrackedState : IO Unit :=
    state.application.modify fun application => {
      application with
      workspaces := application.workspaces.erase workspace.workspaceId
    }
  let resultJson (dropped invalidatedHandles : Bool) (reason? : Option String := none) : Json :=
    Json.mkObj <| [
      ("workspace", toJson workspace.descriptor),
      ("dropped", toJson dropped),
      ("invalidated_handles", toJson invalidatedHandles)
    ] ++ match reason? with
      | some reason => [("reason", toJson reason)]
      | none => []
  match application.runtime? with
  | none =>
      emitProgress? progress? "completed lean_drop_workspace"
      pure <| callToolResult <| resultJson false false (some "notFound")
  | some runtime =>
      let (brokerResp, _) ← runtime.dispatchRequest {
        op := .dropWorkspace
        workspaceId? := some workspace.workspaceId
      }
      if brokerResp.ok then
        match brokerResp.result? with
        | some payload =>
            match fromJson? (α := Beam.Workspace.DropResult) payload with
            | .ok dropped =>
                if dropped.dropped then
                  updateTrackedState
                emitProgress? progress? "completed lean_drop_workspace"
                pure <| callToolResult <|
                  resultJson dropped.dropped dropped.invalidatedHandles dropped.reason?
            | .error err =>
                emitProgress? progress? "lean_drop_workspace failed"
                pure <| callToolErrorResult <| ToolError.invalidResult
                  s!"invalid workspace drop result: {err}"
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
    (state : ServerState)
    (opts : Options) : IO Json := do
  let application ← state.applicationState
  let identity ← serverIdentity opts none (some application.runtime?.isSome)
  pure <| callToolResult identity.asJson

private def collectFeedbackRuntimePayload
    (runtime? : Option Beam.Broker.ServerRuntime)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath)
    (warnings : Array String) : IO (Json × Json × Array String) := do
  match runtime? with
  | none =>
      pure (Json.null, Json.null, warnings.push "no active MCP Lean runtime was available for stats/open-files")
  | some runtime =>
      let (statsResp, _) ← runtime.dispatchRequest {
        op := .stats
        workspaceId? := some workspaceId
        root? := some root.toString
      }
      let (stats, warnings) := Beam.Feedback.responsePayloadOrWarning "stats" statsResp warnings
      let (openResp, _) ← runtime.dispatchRequest {
        op := .openDocs
        workspaceId? := some workspaceId
        root? := some root.toString
      }
      let (openDocs, warnings) := Beam.Feedback.responsePayloadOrWarning "open-files" openResp warnings
      pure (stats, openDocs, warnings)

private def feedbackAllowedRoots
    (root : System.FilePath) : IO (Array System.FilePath) := do
  let control ← Beam.Daemon.controlDir root
  pure #[root, control]

private def confidentialServerIdentity (runtimeActive : Bool) : Beam.Version.Identity := {
  name := Beam.Version.mcpServerName
  mcpProtocol? := some Beam.Version.mcpProtocolVersion
  runtimeActive? := some runtimeActive
}

private def feedbackIncludeCollected (arguments : Json) : Except String Bool := do
  match arguments.getObjVal? "include_collected" with
  | .ok value =>
      match fromJson? (α := Bool) value with
      | .ok includeCollected => pure includeCollected
      | .error err => throw s!"invalid 'include_collected': {err}"
  | .error _ => pure false

/-- Project schema-validated MCP arguments onto the transport-independent feedback input. -/
private def feedbackCoreInputArguments (arguments : Json) : Json :=
  match arguments with
  | .obj fields =>
      Json.mkObj <| (Std.TreeMap.Raw.toList fields).filter fun (field, _) =>
        Beam.Feedback.inputFields.contains field
  | other => other

private def handleBeamFeedback
    (opts : Options)
    (descriptor : Beam.Workspace.Descriptor)
    (workspaceId : Beam.Broker.WorkspaceId)
    (root : System.FilePath)
    (runtime? : Option Beam.Broker.ServerRuntime)
    (arguments : Json)
    (progress? : Option ProgressEmitter) : IO Json := do
  let input ←
    match fromJson? (α := Beam.Feedback.Input) (feedbackCoreInputArguments arguments) with
    | .ok input => pure input
    | .error err =>
        emitProgress? progress? "beam_feedback_report failed"
        return callToolErrorResult <| ToolError.invalidInput err
  let includeCollected ←
    match feedbackIncludeCollected arguments with
    | .ok includeCollected => pure includeCollected
    | .error err =>
        emitProgress? progress? "beam_feedback_report failed"
        return callToolErrorResult <| ToolError.invalidInput err
  emitProgress? progress? <|
    if input.confidential then
      "preparing confidential beam_feedback_report"
    else
      "collecting beam_feedback_report context"
  let generatedAt ← Beam.utcTimestamp
  let collection ←
    if input.confidential then
      let identity := confidentialServerIdentity runtime?.isSome
      pure {
        generatedAt
        data := Json.mkObj [("identity", identity.asJson)]
      }
    else do
      let identity ← serverIdentity opts (some root) (some runtime?.isSome)
      let daemon ← Beam.Daemon.daemonDebugContextJson root
      let warnings := Beam.Daemon.daemonDebugWarnings daemon
      let (stats, openDocs, warnings') ←
        collectFeedbackRuntimePayload runtime? workspaceId root warnings
      pure {
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
  let allowedRoots ←
    if Beam.Feedback.Internal.needsEvidenceRoots input then
      feedbackAllowedRoots root
    else
      pure #[]
  try
    let result ← Beam.Feedback.buildResult input collection {
      root? := some root
      allowedRoots
    }
    let markdown ← Beam.Feedback.renderMcpMarkdown input collection includeCollected
    emitProgress? progress? "completed beam_feedback_report"
    let result := Beam.Feedback.resultMcpJson result markdown includeCollected
    let result :=
      if input.confidential then result
      else result.setObjVal! "workspace" (toJson descriptor)
    pure <| callToolResult result
  catch e =>
    emitProgress? progress? "beam_feedback_report failed"
    pure <| callToolErrorResult <| ToolError.invalidInput e.toString

private def brokerRequestForTool
    (root : System.FilePath)
    (workspaceId : Beam.Broker.WorkspaceId)
    (params : CallToolParams)
    (clientRequestId : String) : Except String Beam.Broker.Request := do
  match params.name.kind with
  | .leanOperation operation => do
      let req ← leanOperationToBrokerRequest operation root.toString workspaceId params.arguments
      pure { req with clientRequestId? := some clientRequestId }
  | _ =>
      throw s!"{params.name.key} is handled locally and does not map to a Lean broker request"

def Internal.handleToolCall
    (state : ServerState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (brokerClientRequestId : String)
    (beforeDispatch : Beam.Broker.ServerRuntime → IO Bool)
    (req : Request)
    (admitted : AdmittedRequestContext)
    (parsedParams : Except String CallToolParams)
    (notifications : NotificationSink) : IO (Except RpcError Json) := do
  let logPolicy :=
    match admitted with
    | .legacy => DiagnosticLogPolicy.legacy state
    | .modern context => DiagnosticLogPolicy.request context.logLevel?
  let notifier : Notifier := { logPolicy, sink := notifications }
  let params ←
    match parsedParams with
    | .ok params => pure params
    | .error err => return .error <| RpcError.invalidParams err
  let progress? ← ProgressEmitter.create? params.progressToken? notifier.send
  Internal.traceMcp
    s!"tools/call start id={req.id.label} tool={params.name.key} progressToken={params.progressToken?.isSome}"
  match params.name.validateInputFields params.arguments with
  | .error err =>
      emitProgress? progress? s!"failed {params.name.key}"
      return .ok <| callToolErrorResult <| ToolError.invalidInput err
  | .ok () => pure ()
  if params.name == .leanDropWorkspace then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← setupMutex.atomically do
      handleDropWorkspace state params.arguments progress?
    Internal.traceMcp s!"tools/call workspace drop complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .beamVersion then
    let result ← handleBeamVersion state opts
    Internal.traceMcp s!"tools/call version complete id={req.id.label} tool={params.name.key}"
    return .ok result
  if params.name == .beamStats then
    emitProgress? progress? s!"starting {params.name.key}"
    let result ← handleBeamStats state progress?
    Internal.traceMcp s!"tools/call stats complete id={req.id.label} tool={params.name.key}"
    return .ok result
  let workspace ←
    match ← resolveWorkspace params.arguments with
    | .ok workspace => pure workspace
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        return .ok <| callToolErrorResult err
  Internal.traceMcp
    s!"tools/call workspace resolved id={req.id.label} root={workspace.root}"
  if params.name == .beamFeedbackReport then
    emitProgress? progress? s!"starting {params.name.key}"
    let application ← state.applicationState
    let selectedRuntime? :=
      if application.workspaces.get? workspace.workspaceId == some workspace.root then
        application.runtime?
      else
        none
    let result ← handleBeamFeedback opts workspace.descriptor workspace.workspaceId
      workspace.root selectedRuntime? params.arguments progress?
    Internal.traceMcp s!"tools/call feedback complete id={req.id.label} tool={params.name.key}"
    return .ok result
  emitProgress? progress? s!"starting {params.name.key}"
  emitProgress? progress? s!"preparing {params.name.key}"
  let brokerReq ←
    match brokerRequestForTool workspace.root workspace.workspaceId params brokerClientRequestId with
    | .ok brokerReq => pure brokerReq
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        Internal.traceMcp s!"tools/call invalid input id={req.id.label} tool={params.name.key} error={err}"
        return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let (runtime, root) ←
    match ← ensureRuntimeForWorkspace state opts setupMutex workspace.workspaceId workspace.root with
    | .ok runtimeAndRoot =>
        Internal.traceMcp s!"tools/call runtime ready id={req.id.label} tool={params.name.key}"
        pure runtimeAndRoot
    | .error err =>
        emitProgress? progress? s!"failed {params.name.key}"
        Internal.traceMcp s!"tools/call runtime failed id={req.id.label} tool={params.name.key}"
        return .error err
  unless ← beforeDispatch runtime do
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
      let result := Beam.Workspace.addWorkspaceDescriptor root result
      pure <| .ok <| callToolResult result
  | .error err =>
      Internal.traceMcp s!"tools/call tool error id={req.id.label} tool={params.name.key}"
      pure <| .ok <| callToolErrorResult err

private def handleReadyOperationRequest
    (state : ServerState)
    (opts : Options)
    (setupMutex : Std.Mutex Unit)
    (brokerClientRequestId : String)
    (req : Request)
    (admitted : AdmittedRequestContext)
    (notifications : NotificationSink) : IO Json := do
  let era := admitted.era
  match req.method with
  | "tools/list" =>
      match admitted with
      | .modern _ =>
          match validateToolsListParams req.params? with
          | .error err => return errorResponse req.id (RpcError.invalidParams err)
          | .ok () => pure ()
      | .legacy =>
          match validateLegacyToolsListParams req.params? with
          | .error err => return errorResponse req.id (RpcError.invalidParams err)
          | .ok () => pure ()
      let result :=
        match admitted with
        | .legacy => toolsListResult
        | .modern _ => modernToolsListResult
      pure <| successResponseForEra era req.id result
  | "tools/call" =>
      let parsedParams := parseCallToolParams req.params?
      match ← Internal.handleToolCall state opts setupMutex brokerClientRequestId
          (fun _ => pure true) req admitted parsedParams notifications with
      | .ok result => pure <| successResponseForEra era req.id result
      | .error err => pure <| errorResponse req.id err
  | method =>
      pure <| errorResponse req.id (RpcError.methodNotFound method)

private def protocolFamilyConflict (active requested : String) : RpcError :=
  RpcError.invalidRequest
    s!"MCP transport already selected the {active} protocol family; {requested} traffic is not allowed"

private inductive ProtocolAdmissionMode : Type → Type where
  | compatible : ProtocolAdmissionMode RequestEra
  | operation : ProtocolAdmissionMode AdmittedRequestContext

private def missingModernRequestMetadata : RpcError :=
  RpcError.invalidParams
    "modern MCP requests require _meta.io.modelcontextprotocol/protocolVersion and _meta.io.modelcontextprotocol/clientCapabilities"

private def requestEraForState
    (current : ProtocolState)
    (evidence : RequestProtocolEvidence) : Except RpcError RequestEra :=
  match evidence with
  | .legacyInitialize => .ok .legacy
  | .modern context => .ok <| .modern context
  | .unmarked =>
      match current with
      | .modern => .error missingModernRequestMetadata
      | .undecided | .legacy _ => .ok .legacy

private def compatibleProtocolRequest
    (current : ProtocolState)
    (evidence : RequestProtocolEvidence) : Except RpcError (ProtocolState × RequestEra) := do
  let era ← requestEraForState current evidence
  match current, era with
  | .legacy _, .modern _ =>
      .error <| protocolFamilyConflict "legacy" "modern"
  | .modern, .legacy =>
      .error <| protocolFamilyConflict "modern" "legacy"
  | _, _ => .ok (current, era)

private def protocolAdmissionTransition
    {Result : Type}
    (mode : ProtocolAdmissionMode Result)
    (current : ProtocolState)
    (evidence : RequestProtocolEvidence) : Except RpcError (ProtocolState × Result) :=
  match mode with
  | .compatible => compatibleProtocolRequest current evidence
  | .operation => do
      let (_, era) ← compatibleProtocolRequest current evidence
      match current, era with
      | .undecided, .modern context => .ok (.modern, .modern context)
      | .modern, .modern context => .ok (.modern, .modern context)
      | .undecided, .legacy =>
          .error <| RpcError.invalidRequest
            "initialize must complete before MCP operation requests"
      | .legacy legacy, .legacy =>
          match legacy.phase with
          | .awaitingInitialized =>
              .error <| RpcError.invalidRequest
                "notifications/initialized is required before MCP operation requests"
          | .ready => .ok (.legacy legacy, .legacy)
      | .legacy _, .modern _ =>
          .error <| protocolFamilyConflict "legacy" "modern"
      | .modern, .legacy =>
          .error <| protocolFamilyConflict "modern" "legacy"

private def admitProtocolRequest
    (state : ServerState)
    (mode : ProtocolAdmissionMode Result)
    (evidence : RequestProtocolEvidence) : IO (Except RpcError Result) :=
  state.protocol.atomically do
    let current ← get
    match protocolAdmissionTransition mode current evidence with
    | .error err => pure <| .error err
    | .ok (next, result) =>
        set next
        pure <| .ok result

def Internal.admitCompatibleRequest
    (state : ServerState)
    (evidence : RequestProtocolEvidence) : IO (Except RpcError RequestEra) :=
  admitProtocolRequest state .compatible evidence

def Internal.admitOperationRequest
    (state : ServerState)
    (evidence : RequestProtocolEvidence) : IO (Except RpcError AdmittedRequestContext) :=
  admitProtocolRequest state .operation evidence

private def initializeLegacyProtocol (state : ServerState) : IO (Except RpcError Unit) :=
  state.protocol.atomically do
    match ← get with
    | .undecided =>
        set <| ProtocolState.legacy {}
        pure <| .ok ()
    | .legacy _ =>
        pure <| .error <| RpcError.invalidRequest "initialize has already completed"
    | .modern =>
        pure <| .error <| protocolFamilyConflict "modern" "legacy"

private def legacyProtocolState? (state : ServerState) : IO (Option LegacyProtocolState) :=
  state.protocol.atomically do
    match ← get with
    | .legacy legacy => pure <| some legacy
    | .undecided | .modern => pure none

private def handleSetLogLevel
    (state : ServerState)
    (req : Request) : IO Json := do
  match parseSetLogLevelParams req.params? with
  | .ok level =>
      let updated : Except RpcError Unit ← state.protocol.atomically do
        match ← get with
        | .legacy legacy =>
            set <| ProtocolState.legacy { legacy with logLevel := level }
            pure <| Except.ok ()
        | .undecided =>
            pure <| Except.error <|
              RpcError.invalidRequest "initialize must complete before MCP logging requests"
        | .modern =>
            pure <| Except.error <| protocolFamilyConflict "modern" "legacy"
      match updated with
      | .ok () => pure <| successResponse req.id (Json.mkObj [])
      | .error err => pure <| errorResponse req.id err
  | .error err =>
      pure <| errorResponse req.id (RpcError.invalidParams err)

def Internal.handleRequestForProtocol
    (state : ServerState)
    (opts : Options)
    (req : Request)
    (evidence : RequestProtocolEvidence)
    (notifications : NotificationSink := {}) : IO Json := do
  let setupMutex ← Std.Mutex.new ()
  let brokerClientRequestId := s!"mcp:sync:{req.id.label}"
  let era ←
    match ← Internal.admitCompatibleRequest state evidence with
    | .error err => return errorResponse req.id err
    | .ok era => pure era
  match req.method with
  | "initialize" =>
      match era with
      | .modern _ =>
          pure <| errorResponse req.id (RpcError.methodNotFound req.method)
      | .legacy =>
          match parseLegacyInitializeParams req.params? with
          | .error err => pure <| errorResponse req.id (RpcError.invalidParams err)
          | .ok _ =>
              match ← initializeLegacyProtocol state with
              | .ok () => pure <| successResponse req.id initializeResult
              | .error err => pure <| errorResponse req.id err
  | "server/discover" =>
      match validateDiscoverParams req.params? with
      | .ok () => pure <| successResponseForEra era req.id discoverResult
      | .error err => pure <| errorResponse req.id (RpcError.invalidParams err)
  | "ping" =>
      match era with
      | .modern _ =>
          pure <| errorResponse req.id (RpcError.methodNotFound req.method)
      | .legacy =>
          match ← Internal.admitOperationRequest state evidence with
          | .error err => pure <| errorResponse req.id err
          | .ok _ =>
              match validateLegacyPingParams req.params? with
              | .ok () => pure <| successResponse req.id (Json.mkObj [])
              | .error err => pure <| errorResponse req.id (RpcError.invalidParams err)
  | "logging/setLevel" =>
      match era with
      | .modern _ =>
          pure <| errorResponse req.id (RpcError.methodNotFound req.method)
      | .legacy =>
          handleSetLogLevel state req
  | "tools/list" | "tools/call" =>
      match ← Internal.admitOperationRequest state evidence with
      | .error err => pure <| errorResponse req.id err
      | .ok admitted =>
          handleReadyOperationRequest
            state opts setupMutex brokerClientRequestId req admitted notifications
  | method =>
      match era with
      | .modern _ =>
          pure <| errorResponse req.id (RpcError.methodNotFound method)
      | .legacy =>
          if (← legacyProtocolState? state).isNone then
            pure <| errorResponse req.id <|
              RpcError.invalidRequest "initialize must be the first MCP operation"
          else
            pure <| errorResponse req.id (RpcError.methodNotFound method)

def handleRequest
    (state : ServerState)
    (opts : Options)
    (req : Request)
    (notifications : NotificationSink := {}) : IO Json := do
  match req.protocolEvidence with
  | .ok evidence => Internal.handleRequestForProtocol state opts req evidence notifications
  | .error err => pure <| errorResponse req.id err

def handleNotification
    (state : ServerState)
    (notification : Notification) : IO Unit := do
  match notification.method with
  | "notifications/initialized" =>
      match validateInitializedParams notification.params? with
      | .error err => Internal.traceMcp s!"ignoring invalid notifications/initialized: {err}"
      | .ok () =>
          state.protocol.atomically do
            match ← get with
            | .legacy legacy => set <| ProtocolState.legacy { legacy with phase := .ready }
            | .undecided | .modern => pure ()
  | _ => pure ()

def handleJson
    (state : ServerState)
    (opts : Options)
    (json : Json)
    (notifications : NotificationSink := {}) : IO (Option Json) := do
  match Incoming.fromJson? json with
  | .ok (.request req) =>
      pure <| some <| ← handleRequest state opts req notifications
  | .ok (.notification notification) =>
      handleNotification state notification
      pure none
  | .error err =>
      let id :=
        match RequestId.fromEnvelope? json with
        | some id => id.json
        | none => Json.null
      pure <| some <| errorResponse id (RpcError.invalidRequest err)

end Beam.Mcp.Server
