/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Communication
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import Lean.Data.Lsp.Internal
import Lean.Parser.Module
import RunAt.Protocol
import RunAt.Internal.DirectImports
import RunAt.Internal.SaveSupport
import Beam.Broker.Config
import Beam.Broker.DocumentState
import Beam.Broker.Errors
import Beam.Broker.Metrics
import Beam.Broker.OpenDocs
import Beam.Broker.Pending
import Beam.Broker.Protocol
import Beam.Broker.RequestArgs
import Beam.Broker.Transport
import Beam.Broker.Lean
import Beam.Broker.Deps
import Beam.Broker.LakeSave
import Beam.Broker.Readiness
import Beam.Path
import Std.Sync.Mutex

open Lean
open Lean.JsonRpc
open Lean.Lsp
open IO.FS.Stream

namespace Beam.Broker

abbrev brokerStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  -- Keep backend stderr away from MCP stdio. Inheriting it can corrupt
  -- client framing; piping and draining it caused macOS save_olean hangs.
  stderr := .null

structure Session where
  backend : Backend
  root : System.FilePath
  epoch : Nat
  sessionToken : String
  proc : IO.Process.Child brokerStdio
  stdin : IO.FS.Stream
  stdout : IO.FS.Stream
  pending : PendingRequestStore
  nextId : Nat := 1
  nextEventSeq : Nat := 1
  moduleHistory : Std.TreeMap String ModuleHistory := {}
  docs : Std.TreeMap String DocState := {}

structure BackendState where
  nextEpoch : Nat := 1
  session? : Option Session := none

structure State where
  config : BrokerConfig
  startMonoNanos : Nat := 0
  nextFileSnapshotSeq : Nat := 1
  lean : BackendState := {}
  rocq : BackendState := {}
  leanMetrics : BackendMetrics := {}
  rocqMetrics : BackendMetrics := {}
  streamSink? : Option (StreamMessage → IO Unit) := none
  currentClientRequestId? : Option String := none

abbrev M := StateRefT State IO

private def mkSessionToken : IO String := do
  let pid ← IO.Process.getPID
  let now ← IO.monoNanosNow
  pure s!"{pid}-{now}"

private def resolveRoot (root : System.FilePath) : IO System.FilePath :=
  Beam.resolveExistingPath root

private def resolvePath (root : System.FilePath) (path : System.FilePath) : IO System.FilePath :=
  Beam.resolvePathAgainstRoot root path

def sessionUri (path : System.FilePath) : String :=
  (System.Uri.pathToUri path : String)

private partial def waitForTaskWithTimeout
    (task : Task α)
    (timeoutMs : Nat)
    (pollMs : Nat := 50) : IO (Option α) := do
  let rec loop (remainingMs : Nat) : IO (Option α) := do
    if ← IO.hasFinished task then
      return some (← IO.wait task)
    if remainingMs == 0 then
      return none
    IO.sleep pollMs.toUInt32
    loop (remainingMs - min pollMs remainingMs)
  loop timeoutMs

private def sessionShutdownReplyTimeoutMs : Nat :=
  1000

private def killCommand? : IO (Option System.FilePath) := do
  for candidate in [System.FilePath.mk "/bin/kill", System.FilePath.mk "/usr/bin/kill"] do
    if ← candidate.pathExists then
      return some candidate
  pure none

private partial def waitForProcessExitWithTimeout
    (proc : IO.Process.Child brokerStdio)
    (timeoutMs : Nat)
    (pollMs : Nat := 50) : IO Bool := do
  let rec loop (remainingMs : Nat) : IO Bool := do
    match ← (try
      proc.tryWait
    catch _ =>
      pure none) with
    | some _ => pure true
    | none =>
        if remainingMs == 0 then
          pure false
        else
          IO.sleep pollMs.toUInt32
          loop (remainingMs - min pollMs remainingMs)
  loop timeoutMs

private def shutdownSession (session : Session) : IO Unit := do
  try
    writeLspRequest session.stdin ({ id := 0, method := "shutdown", param := Json.null : Lean.JsonRpc.Request Json })
    let task ← IO.asTask (prio := Task.Priority.dedicated) session.stdout.readLspMessage
    let _ ← waitForTaskWithTimeout task sessionShutdownReplyTimeoutMs
    pure ()
  catch _ =>
    pure ()
  try
    writeLspNotification session.stdin ({ method := "exit", param := Json.null : Lean.JsonRpc.Notification Json })
  catch _ =>
    pure ()
  unless ← waitForProcessExitWithTimeout session.proc sessionShutdownReplyTimeoutMs do
    try
      session.proc.kill
    catch _ =>
      pure ()
    try
      if let some kill := ← killCommand? then
        let _ ← IO.Process.output {
          cmd := kill.toString
          args := #["-9", toString session.proc.pid.toNat]
        }
        pure ()
    catch _ =>
      pure ()
    discard <| waitForProcessExitWithTimeout session.proc sessionShutdownReplyTimeoutMs
  try
    discard <| session.proc.tryWait
  catch _ =>
    pure ()

private def sessionExited (session : Session) : IO Bool := do
  try
    pure (← session.proc.tryWait).isSome
  catch _ =>
    pure true

private def getBackendState (state : State) (backend : Backend) : BackendState :=
  match backend with
  | .lean => state.lean
  | .rocq => state.rocq

private def setBackendState (state : State) (backend : Backend) (backendState : BackendState) : State :=
  match backend with
  | .lean => { state with lean := backendState }
  | .rocq => { state with rocq := backendState }

private def getBackendMetrics (state : State) (backend : Backend) : BackendMetrics :=
  match backend with
  | .lean => state.leanMetrics
  | .rocq => state.rocqMetrics

private def setBackendMetrics (state : State) (backend : Backend) (metrics : BackendMetrics) : State :=
  match backend with
  | .lean => { state with leanMetrics := metrics }
  | .rocq => { state with rocqMetrics := metrics }

private def recordSessionSpawn (backend : Backend) (restart : Bool) : M Unit := do
  modify fun state =>
    let metrics := getBackendMetrics state backend
    let metrics := {
      metrics with
      sessionStarts := metrics.sessionStarts + 1
      sessionRestarts := metrics.sessionRestarts + (if restart then 1 else 0)
    }
    setBackendMetrics state backend metrics

private def recordRequestMetrics
    (backend : Backend)
    (op : String)
    (ok : Bool)
    (errorCode? : Option String)
    (latencyMs : Nat) : M Unit := do
  modify fun state =>
    let metrics := getBackendMetrics state backend
    let opStats := (metrics.ops.get? op).getD {}
    let opStats := opStats.record ok errorCode? latencyMs
    let metrics := {
      metrics with
      requestCount := metrics.requestCount + 1
      successCount := metrics.successCount + (if ok then 1 else 0)
      errorCount := metrics.errorCount + (if ok then 0 else 1)
      cancelledCount := metrics.cancelledCount + (if isCancelledCode errorCode? then 1 else 0)
      workerExitedCount := metrics.workerExitedCount + (if isWorkerExitedCode errorCode? then 1 else 0)
      invalidParamsCount := metrics.invalidParamsCount + (if isInvalidParamsCode errorCode? then 1 else 0)
      ops := metrics.ops.insert op opStats
    }
    setBackendMetrics state backend metrics

private def sessionSnapshotJson (session? : Option Session) : Json :=
  match session? with
  | none => Json.mkObj [("active", toJson false)]
  | some session =>
      Json.mkObj [
        ("active", toJson true),
        ("root", toJson session.root.toString),
        ("epoch", toJson session.epoch),
        ("openDocCount", toJson session.docs.toList.length)
      ]

private def statsPayload : M Json := do
  let state ← get
  let now ← IO.monoNanosNow
  let uptimeMs := (now - state.startMonoNanos) / 1000000
  pure <| Json.mkObj [
    ("root", toJson state.config.root.toString),
    ("uptimeMs", toJson uptimeMs),
    ("sessions", Json.mkObj [
      ("lean", sessionSnapshotJson state.lean.session?),
      ("rocq", sessionSnapshotJson state.rocq.session?)
    ]),
    ("byBackend", Json.mkObj [
      ("lean", backendMetricsJson state.leanMetrics),
      ("rocq", backendMetricsJson state.rocqMetrics)
    ])
  ]

private def resetMetrics (startMonoNanos : Nat) : M Unit := do
  modify fun state => {
    state with
    leanMetrics := {}
    rocqMetrics := {}
    startMonoNanos := startMonoNanos
  }

private def nextRequestId (session : Session) : Session × RequestID :=
  let id : RequestID := session.nextId
  ({ session with nextId := session.nextId + 1 }, id)

partial def sessionReaderLoop (session : Session) : IO Unit := do
  try
    let msg ← session.stdout.readLspMessage
    match msg with
    | .response id result =>
        if let some pending ← PendingRequestStore.remove session.pending id then
          PendingRequest.resolveResponse pending result
    | .responseError id code message data? =>
        if let some pending ← PendingRequestStore.remove session.pending id then
          PendingRequest.resolveError pending code message data?
    | .notification "$/lean/fileProgress" (some param) =>
        let pending ← PendingRequestStore.snapshot session.pending
        for req in pending do
          PendingRequest.observeProgress req param
    | .notification "textDocument/publishDiagnostics" (some param) =>
        let pending ← PendingRequestStore.snapshot session.pending
        for req in pending do
          PendingRequest.observeDiagnostics session.root req param
    | _ =>
        pure ()
    sessionReaderLoop session
  catch e =>
    PendingRequestStore.failAll session.pending <| brokerFailureMessage {
      code := .workerExited
      message := e.toString
    }
    try
      session.proc.kill
    catch _ =>
      pure ()
    try
      discard <| session.proc.tryWait
    catch _ =>
      pure ()

private def startRequestJsonTrackedDetailed
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Session × IO.Promise (Except String PendingResult)) := do
  let (session, id) := nextRequestId session
  let progressRef ← IO.mkRef (initialProgress? <|> tracked.map (fun _ => {}))
  let diagnosticsRef ← IO.mkRef #[]
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  let promise ← IO.Promise.new
  PendingRequestStore.insert session.pending id {
      clientRequestId? := clientRequestId?
      promise := promise
      tracked? := tracked
      progressRef := progressRef
      diagnosticsRef := diagnosticsRef
      emitProgress? := emitProgress?
      fullDiagnostics := fullDiagnostics
      seenDiagnosticKeysRef := seenDiagnosticKeysRef
      emitDiagnostic? := emitDiagnostic?
      : PendingRequest
    }
  try
    writeLspRequest session.stdin ({ id, method, param : Lean.JsonRpc.Request Json })
    pure (session, promise)
  catch e =>
    discard <| PendingRequestStore.remove session.pending id
    try
      promise.resolve (.error e.toString)
    catch _ =>
      pure ()
    throw e

def sendRequestJsonTrackedDetailed
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Session × Json × Option SyncFileProgress × Array Diagnostic) := do
  let (session, promise) ←
    startRequestJsonTrackedDetailed session method param clientRequestId? tracked initialProgress?
      emitProgress? fullDiagnostics emitDiagnostic?
  let pending ← PendingRequest.awaitResult promise
  pure (session, pending.result, pending.progress?, pending.diagnostics)

private def sendRequestJsonTracked
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Session × Json × Option SyncFileProgress) := do
  let (session, result, progress?, _) ←
    sendRequestJsonTrackedDetailed session method param clientRequestId? tracked initialProgress? emitProgress?
  pure (session, result, progress?)

private def sendRequestJson (session : Session) (method : String) (param : Json) : IO (Session × Json) := do
  let (session, result, _) ← sendRequestJsonTracked session method param
  pure (session, result)

private partial def awaitInitializeResponse (stdout : IO.FS.Stream) : IO Unit := do
  let msg ← stdout.readLspMessage
  match msg with
  | .response id _ =>
      if id == 0 then
        pure ()
      else
        throwBrokerFailure {
          code := .internalError
          message := s!"unexpected response id {id} before initialize completed"
        }
  | .responseError id _code message _ =>
      if id == 0 then
        throwBrokerFailure { code := .internalError, message := s!"initialize failed: {message}" }
      else
        throwBrokerFailure {
          code := .internalError
          message := s!"unexpected response error id {id} before initialize completed: {message}"
        }
  | .notification .. =>
      awaitInitializeResponse stdout
  | .request .. =>
      throwBrokerFailure {
        code := .internalError
        message := "unexpected server request before initialize completed"
      }

private def ensureSession (backend : Backend) : M Session := do
  let state ← get
  let config := state.config
  let root := config.root
  let backendState := getBackendState state backend
  let (backendState, restart) ← match backendState.session? with
    | some session =>
        if ← sessionExited session then
          shutdownSession session
          pure ({ backendState with session? := none, nextEpoch := backendState.nextEpoch + 1 }, true)
        else
          pure (backendState, false)
    | none =>
        pure (backendState, false)
  match backendState.session? with
  | some session =>
      modify fun st => setBackendState st backend backendState
      pure session
  | none =>
      let (cmd, args) ← backendCommand config backend
      let proc ← IO.Process.spawn {
        toStdioConfig := brokerStdio
        cmd := cmd
        args := args
        cwd := root.toString
      }
      let stdin := IO.FS.Stream.ofHandle proc.stdin
      let stdout := IO.FS.Stream.ofHandle proc.stdout
      let pending ← PendingRequestStore.create
      let sessionToken ← mkSessionToken
      let mut session : Session := {
        backend
        root
        epoch := backendState.nextEpoch
        sessionToken
        proc
        stdin
        stdout
        pending
      }
      writeLspRequest stdin ({ id := 0, method := "initialize", param := initializeParams backend root : Lean.JsonRpc.Request Json })
      awaitInitializeResponse stdout
      writeLspNotification stdin ({ method := "initialized", param := Json.mkObj [] : Lean.JsonRpc.Notification Json })
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        try
          sessionReaderLoop session
        catch e =>
          IO.eprintln s!"broker session reader task failed: {e.toString}"
      recordSessionSpawn backend restart
      let backendState := { backendState with session? := some session }
      modify fun st => setBackendState st backend backendState
      pure session

private def sendNotificationJson (session : Session) (method : String) (param : Json) : IO Session := do
  writeLspNotification session.stdin ({ method, param : Lean.JsonRpc.Notification Json })
  pure session

/--
An immutable view of a source file used to synchronize the LSP session.

The file contents and metadata are computed before the broker state mutex is
held. This keeps potentially slow filesystem work out of the critical section.
For request handlers that can race with each other, `readSeq` is reserved while
holding the mutex and is later used by `DocumentState.syncFileDecision` to
ignore stale snapshots that completed after a newer read was already applied.
-/
private structure FileSyncSnapshot where
  path : System.FilePath
  uri : DocumentUri
  text : String
  file : DocumentState.FileSnapshot

private def readFileSyncSnapshot
    (root path : System.FilePath)
    (backend : Backend)
    (readSeq : Nat := 0) : IO FileSyncSnapshot := do
  let path ← resolvePath root path
  let text ← IO.FS.readFile path
  let textMTime ← Lake.getFileMTime path
  pure {
    path
    uri := sessionUri path
    text
    file := {
      textHash := hash text
      textTraceHash := Lake.Hash.ofText text
      textMTime
      readSeq
      moduleName? := DocumentState.trackedModuleName? root path backend
    }
  }

private def syncFileSnapshot (session : Session) (snapshot : FileSyncSnapshot) : IO Session := do
  let decision := DocumentState.syncFileDecision session.docs snapshot.uri snapshot.file
  let session ←
    match decision.action with
    | .open =>
      let param := toJson ({
        textDocument := {
          uri := snapshot.uri
          languageId := match session.backend with | .lean => "lean" | .rocq => "rocq"
          version := decision.version
          text := snapshot.text
        } : DidOpenTextDocumentParams
      })
      sendNotificationJson session "textDocument/didOpen" param
    | .change =>
        let param := toJson ({
          textDocument := { uri := snapshot.uri, version? := some decision.version }
          contentChanges := #[TextDocumentContentChangeEvent.fullChange snapshot.text]
          : DidChangeTextDocumentParams
        })
        sendNotificationJson session "textDocument/didChange" param
    | .unchanged =>
        pure session
  pure { session with docs := decision.docs }

private def requireDocState (session : Session) (uri : String) : IO DocState := do
  DocumentState.requireDocState session.docs uri

private def closeFile (session : Session) (path : System.FilePath) : IO Session := do
  let path ← resolvePath session.root path
  let uri := sessionUri path
  if session.docs.get? uri |>.isNone then
    pure session
  else
    let param := toJson ({ textDocument := { uri := uri } : DidCloseTextDocumentParams })
    let session ← sendNotificationJson session "textDocument/didClose" param
    pure { session with docs := session.docs.erase uri }

private def recordFileProgress (session : Session) (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : Session :=
  { session with docs := DocumentState.recordFileProgress session.docs uri fileProgress? }

private def decodeResponseAs [FromJson α] (json : Json) : IO α := do
  match fromJson? json with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"invalid backend response payload: {err}\n{json.compress}"

private def ensureSyncBarrierComplete
    (uri : DocumentUri)
    (version : Nat)
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic := #[]) : IO Unit := do
  let decision := decideSyncBarrier uri version none progress? diagnostics
  if decision.incomplete then
    throwBrokerFailure {
      code := .syncBarrierIncomplete
      message := decision.message?.getD (syncBarrierIncompleteMessage uri version progress?)
    }

private def trackedPathLabel (root : System.FilePath) (uri : DocumentUri) : String :=
  match workspacePath? root uri with
  | some path => path
  | none => uri

private def applyVersionMarkResult
    (session : Session)
    (result : DocumentState.VersionMarkResult) : Session :=
  if result.applied then
    { session with
      nextEventSeq := session.nextEventSeq + 1
      docs := result.docs
      moduleHistory := result.moduleHistory
    }
  else
    session

private def markDocSyncedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  let result := DocumentState.markSyncedVersion
    session.docs session.moduleHistory uri version
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def markDocSavedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  let result := DocumentState.markSavedVersion
    session.docs session.moduleHistory uri version
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def openDocsSessionView (session : Session) : OpenDocs.SessionView := {
  backend := session.backend
  root := session.root
  docs := session.docs
}

private def openDocsPayload : M Json := do
  let state ← get
  OpenDocs.payload state.config.root state.config.leanCmd?
    (state.lean.session?.map openDocsSessionView)
    (state.rocq.session?.map openDocsSessionView)

private def wrapHandle (session : Session) (raw : Json) : Json :=
  toJson ({ backend := session.backend, epoch := session.epoch, session := session.sessionToken, raw : Handle })

private def unwrapHandle (session : Session) (handle : Handle) : Except String Json := do
  if handle.backend != session.backend then
    throw "handle belongs to a different backend"
  if handle.epoch != session.epoch || handle.session != session.sessionToken then
    throw "handle belongs to a stale backend session"
  pure handle.raw

private def wrapResultHandle (session : Session) (result : Json) : Json :=
  match result.getObjVal? "handle" with
  | .ok raw =>
      result.setObjVal! "handle" (wrapHandle session raw)
  | .error _ =>
      result

private def updateSession (session : Session) : M Unit := do
  modify fun state =>
    let backendState := getBackendState state session.backend
    setBackendState state session.backend { backendState with session? := some session }

private def handleDepsOp (req : Request) : M (Response × Bool) := do
  let path ←
    match req.pathArg with
    | .ok path => pure path
    | .error resp => return (resp, false)
  let root := (← get).config.root
  let resolvedPath ← resolvePath root path
  let uri := sessionUri resolvedPath
  try
    let some module := normalizeModuleForPath root resolvedPath uri none
      | return (reqError "invalidParams" s!"no Lean module available for {uri}", false)
    let state ← mkDepsQueryState root
    let imports ← requireDirectImports state module.name
    let importedBy ← directImportedBy state module.name
    let importClosure ← collectImportClosure state module.name
    let importedByClosure ← collectImportedByClosure state module.name
    pure (Response.success (depsPayload root module imports importedBy importClosure importedByClosure), false)
  catch e =>
    let msg := e.toString
    if let some resp := decodeJsonRpcError msg then
      pure (resp, false)
    else
      pure (reqError "internalError" msg, false)

private def currentSession? (backend : Backend) : M (Option Session) := do
  let state ← get
  match (getBackendState state backend).session? with
  | none =>
      pure none
  | some session =>
      if ← sessionExited session then
        shutdownSession session
        modify fun st =>
          let backendState := getBackendState st backend
          setBackendState st backend { backendState with session? := none, nextEpoch := backendState.nextEpoch + 1 }
        pure none
      else
        pure (some session)

private def currentSessionForHandle (backend : Backend) : M Session := do
  match ← currentSession? backend with
  | some session => pure session
  | none =>
      throwBrokerFailure {
        code := .contentModified
        message := "handle belongs to a stale backend session"
      }

private def sameSessionIdentity (left right : Session) : Bool :=
  left.backend == right.backend &&
    left.root == right.root &&
    left.epoch == right.epoch &&
    left.sessionToken == right.sessionToken

private def modifyCurrentSessionIfMatching
    (session : Session)
    (f : Session → Session) : M Unit := do
  match ← currentSession? session.backend with
  | some current =>
      if sameSessionIdentity current session then
        updateSession (f current)
      else
        pure ()
  | none =>
      pure ()

structure ServerRuntime where
  state : Std.Mutex State
  endpoint : Transport.Endpoint
  stop : IO.Ref Bool
  activeRequests : ActiveRequestRegistry

def ServerRuntime.withState (server : ServerRuntime) (act : M α) : IO α := do
  server.state.atomically do
    let state ← get
    let (a, state) ← act.run state
    set state
    pure a

def ServerRuntime.create
    (config : BrokerConfig)
    (endpoint : Transport.Endpoint := .tcp 0) : IO ServerRuntime := do
  let startMonoNanos ← IO.monoNanosNow
  pure {
    state := ← Std.Mutex.new { config := config, startMonoNanos := startMonoNanos }
    endpoint := endpoint
    stop := ← IO.mkRef false
    activeRequests := ← ActiveRequestRegistry.create
  }

private def requestTracksActiveRequest : Op → Bool
  | .cancel | .stats | .resetStats | .shutdown | .openDocs => false
  | _ => true

private def recordDispatchMetrics
    (server : ServerRuntime)
    (req : Request)
    (resp : Response)
    (startedAt : Nat) : IO Unit := do
  if requestTracksActiveRequest req.op then
    let finishedAt ← IO.monoNanosNow
    let latencyMs := (finishedAt - startedAt) / 1000000
    server.withState do
      recordRequestMetrics req.backend req.op.key resp.ok (resp.error?.map (·.code)) latencyMs

private def cancelActiveRequest
    (server : ServerRuntime)
    (clientRequestId : String) : IO Bool := do
  if ← ActiveRequestRegistry.markCancelled server.activeRequests clientRequestId then
    let sessions ← server.withState do
      let state ← get
      pure [state.lean.session?, state.rocq.session?]
    for session? in sessions do
      if let some session := session? then
        discard <| PendingRequestStore.cancelMatching session.pending session.stdin clientRequestId
    pure true
  else
    pure false

private def propagatePendingCancellation
    (session : Session)
    (clientRequestId? : Option String)
    (cancelRef? : Option (IO.Ref Bool)) : IO Unit := do
  PendingRequestStore.propagateCancellation session.pending session.stdin clientRequestId? cancelRef?

private def requestStop (server : ServerRuntime) : IO Unit := do
  server.stop.set true
  try
    let conn ← Transport.connect server.endpoint
    Transport.closeConnection conn
  catch _ =>
    pure ()

private def validateRequestRoot (server : ServerRuntime) (req : Request) : IO (Except Response Unit) := do
  let requestedRoot ←
    match req.rootArg with
    | .ok root => pure root
    | .error resp => return .error resp
  let requestedRoot ←
    try
      resolveRoot requestedRoot
    catch e =>
      return .error (reqError "invalidParams" e.toString)
  let daemonRoot ← server.withState do
    pure (← get).config.root
  if requestedRoot != daemonRoot then
    return .error (reqError "invalidParams" s!"Beam daemon serves {daemonRoot}, not {requestedRoot}")
  pure (.ok ())

private def mergeFileProgressIfCurrent
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : IO Unit := do
  server.withState do
    modifyCurrentSessionIfMatching session (fun current => recordFileProgress current uri fileProgress?)

private def withCurrentMatchingSession
    (server : ServerRuntime)
    (session : Session)
    (k : Session → M α) : IO α := do
  server.withState do
    match ← currentSession? session.backend with
    | some current =>
        if sameSessionIdentity current session then
          k current
        else
          throwBrokerFailure {
            code := .workerExited
            message := "broker backend session changed while request was in flight"
          }
    | none =>
        throwBrokerFailure {
          code := .workerExited
          message := "broker backend session exited while request was in flight"
        }

private def sendCurrentSessionRequestDecode [FromJson α]
    (server : ServerRuntime)
    (session : Session)
    (method : String)
    (params : Json) : IO α := do
  withCurrentMatchingSession server session fun current => do
    let (current, payload) ← sendRequestJson current method params
    updateSession current
    decodeResponseAs payload

private structure StartedSyncedRequest where
  session : Session
  uri : DocumentUri
  version : Nat
  priorProgress? : Option SyncFileProgress := none
  tracked : Option (DocumentUri × Nat) := none
  promise : IO.Promise (Except String PendingResult)

private def trackedDocumentVersion (uri : DocumentUri) (docState : DocState) :
    Option (DocumentUri × Nat) :=
  some (uri, docState.version)

private def trackedLeanDocumentVersion
    (backend : Backend)
    (uri : DocumentUri)
    (docState : DocState) : Option (DocumentUri × Nat) :=
  if backend == .lean then
    trackedDocumentVersion uri docState
  else
    none

private def startSyncedDocumentRequest
    (session : Session)
    (snapshot : FileSyncSnapshot)
    (method : String)
    (mkParams : DocumentUri → DocState → Json)
    (trackedFor : DocumentUri → DocState → Option (DocumentUri × Nat))
    (clientRequestId? : Option String := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (fullDiagnostics : Bool := false)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    M StartedSyncedRequest := do
  let session ← syncFileSnapshot session snapshot
  let uri := snapshot.uri
  let docState ← requireDocState session uri
  let tracked := trackedFor uri docState
  let params := mkParams uri docState
  let (session, promise) ←
    startRequestJsonTrackedDetailed session method params
      (clientRequestId? := clientRequestId?)
      (tracked := tracked)
      (initialProgress? := docState.fileProgress?)
      (emitProgress? := emitProgress?)
      (fullDiagnostics := fullDiagnostics)
      (emitDiagnostic? := emitDiagnostic?)
  updateSession session
  pure {
    session
    uri
    version := docState.version
    priorProgress? := docState.fileProgress?
    tracked
    promise
  }

private def awaitSyncedDocumentRequestIO
    (server : ServerRuntime)
    (req : Request)
    (started : StartedSyncedRequest)
    (cancelRef? : Option (IO.Ref Bool) := none) : IO PendingResult := do
  propagatePendingCancellation started.session req.clientRequestId? cancelRef?
  let pending ← PendingRequest.awaitResult started.promise
  if started.tracked.isSome then
    mergeFileProgressIfCurrent server started.session started.uri pending.progress?
  pure pending

private def readRequestSyncSnapshot
    (server : ServerRuntime)
    (req : Request)
    (path : System.FilePath) : IO FileSyncSnapshot := do
  let (root, readSeq) ← server.withState do
    let state ← get
    set { state with nextFileSnapshotSeq := state.nextFileSnapshotSeq + 1 }
    pure (state.config.root, state.nextFileSnapshotSeq)
  -- Reserve the ordering token under the mutex, then do the slow file IO
  -- outside it.
  readFileSyncSnapshot root path req.backend (readSeq := readSeq)

private structure StartedTrackedBarrier where
  session : Session
  uri : DocumentUri
  version : Nat
  priorProgress? : Option SyncFileProgress := none
  promise : IO.Promise (Except String PendingResult)

private def startTrackedDiagnosticsBarrierIO
    (server : ServerRuntime)
    (req : Request)
    (path : System.FilePath)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO StartedTrackedBarrier := do
  let snapshot ← readRequestSyncSnapshot server req path
  server.withState do
    let session ← ensureSession req.backend
    let started ←
      startSyncedDocumentRequest session snapshot "textDocument/waitForDiagnostics"
        (fun uri docState => toJson (WaitForDiagnosticsParams.mk uri docState.version))
        trackedDocumentVersion
        (clientRequestId? := req.clientRequestId?)
        (emitProgress? := emitProgress?)
        (fullDiagnostics := req.fullDiagnostics?.getD false)
        (emitDiagnostic? := emitDiagnostic?)
    pure {
      session := started.session
      uri := started.uri
      version := started.version
      priorProgress? := started.priorProgress?
      promise := started.promise
    }

private def finalizeSavedDoc
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (spec : LeanSaveSpec)
    (closeAfter : Bool) : IO Unit := do
  withCurrentMatchingSession server session fun current => do
    let shouldSendDidSave :=
      match current.docs.get? uri with
      | some docState => docState.version == version
      | none => false
    let current ←
      if shouldSendDidSave then
        sendNotificationJson current "textDocument/didSave" (toJson ({
          textDocument := ({ uri := uri : TextDocumentIdentifier })
          text? := none
          : DidSaveTextDocumentParams
        }))
      else
        pure current
    let current ← sendNotificationJson current "workspace/didChangeWatchedFiles" (toJson ({
      changes := #[
        { uri := (System.Uri.pathToUri spec.ileanPath : String), type := FileChangeType.Changed }
      ]
      : DidChangeWatchedFilesParams
    }))
    let current := markDocSavedVersion current uri version
    let current ←
      if closeAfter && current.docs.contains uri then
        sendNotificationJson current "textDocument/didClose" (toJson ({
          textDocument := ({ uri := uri : TextDocumentIdentifier })
          : DidCloseTextDocumentParams
        }))
      else
        pure current
    let current :=
      if closeAfter then
        { current with docs := current.docs.erase uri }
      else
        current
    updateSession current

private structure SaveOleanCompleted where
  session : Session
  uri : DocumentUri
  version : Nat
  spec : LeanSaveSpec
  payload : Json
  fileProgress? : Option SyncFileProgress := none

private def saveCompletedResponse
    (saved : SaveOleanCompleted)
    (closeAfter : Bool) : Response :=
  let payload :=
    if closeAfter then
      Json.mkObj [("closed", toJson true), ("saved", saved.payload)]
    else
      saved.payload
  responseWithFileProgress (Response.success payload) saved.fileProgress?

private def fetchSyncSaveReadinessIO
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri) : IO SyncSaveReadiness := do
  if session.backend != .lean then
    pure {}
  else
    let method ← IO.ofExcept <| saveReadinessMethod session.backend
    let params := toJson ({
      textDocument := ({ uri := uri : TextDocumentIdentifier })
      : RunAt.Internal.SaveReadinessParams
    })
    let readiness : RunAt.Internal.SaveReadinessResult ←
      sendCurrentSessionRequestDecode server session method params
    pure (syncSaveReadinessOfResult readiness)

private def fetchDirectImportsIO
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri) : IO DirectImportsQueryResult := do
  let method ← IO.ofExcept <| directImportsMethod session.backend
  let params := toJson ({
    textDocument := ({ uri := uri : TextDocumentIdentifier })
    : RunAt.Internal.DirectImportsParams
  })
  let result : RunAt.Internal.DirectImportsResult ←
    sendCurrentSessionRequestDecode server session method params
  pure {
    version := result.version
    imports := result.imports
  }

private def collectStaleDirectDepHintsIO
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat) : IO (Array StaleDirectDepHint) := do
  if session.backend != .lean then
    pure #[]
  else
    let importsResult ← fetchDirectImportsIO server session uri
    withCurrentMatchingSession server session fun current => do
      let targetLastSyncSeq :=
        match current.docs.get? uri with
        | some docState => docState.lastSyncSeq
        | none => 0
      let history := DocumentState.moduleHistorySnapshots current.moduleHistory
      pure <| collectStaleDirectDepHints importsResult version targetLastSyncSeq history

private def saveOleanIO
    (server : ServerRuntime)
    (req : Request)
    (path : System.FilePath)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO SaveOleanCompleted := do
  ensureRequestNotCancelled cancelRef?
  let path ← resolvePath ((← server.withState do pure (← get).config.root)) path
  let started ← startTrackedDiagnosticsBarrierIO server req path emitProgress? emitDiagnostic?
  let (textHash, textTraceHash, textMTime, leanCmd?) ← server.withState do
    let docState ← requireDocState started.session started.uri
    pure (docState.textHash, docState.textTraceHash, docState.textMTime, (← get).config.leanCmd?)
  propagatePendingCancellation started.session req.clientRequestId? cancelRef?
  let barrier ← PendingRequest.awaitResult started.promise
  let barrierDecision :=
    decideSyncBarrier started.uri started.version started.priorProgress? barrier.progress? barrier.diagnostics
  let barrierProgress? := barrierDecision.fileProgress?
  let (_ : WaitForDiagnostics) ← decodeResponseAs barrier.result
  mergeFileProgressIfCurrent server started.session started.uri barrierProgress?
  ensureSyncBarrierComplete started.uri started.version barrierProgress? barrier.diagnostics
  ensureRequestNotCancelled cancelRef?
  let spec ← mkLeanSaveSpec started.session.root path { hash := textTraceHash, mtime := textMTime } leanCmd?
  let method ← IO.ofExcept <| saveArtifactsMethod started.session.backend
  let params := toJson ({
    textDocument := ({ uri := started.uri : TextDocumentIdentifier })
    oleanFile := spec.oleanPath.toString
    ileanFile := spec.ileanPath.toString
    cFile := spec.cPath.toString
    bcFile? := spec.bcPath?.map (fun bcPath => System.FilePath.toString bcPath)
    : RunAt.Internal.SaveArtifactsParams
  })
  let (session, savePromise) ← withCurrentMatchingSession server started.session fun current => do
    let (current, savePromise) ← startRequestJsonTrackedDetailed current method params
      (clientRequestId? := req.clientRequestId?)
    updateSession current
    pure (current, savePromise)
  propagatePendingCancellation session req.clientRequestId? cancelRef?
  let savePending ← PendingRequest.awaitResult savePromise
  let saveResult : RunAt.Internal.SaveArtifactsResult ← decodeResponseAs savePending.result
  if saveResult.version != started.version then
    throw <| IO.userError
      s!"save_olean saved version {saveResult.version}, expected synced version {started.version}"
  if saveResult.textHash != textHash then
    throw <| IO.userError
      s!"save_olean saved text hash {saveResult.textHash}, expected synced hash {textHash}"
  writeLeanSaveTrace spec
  pure {
    session
    uri := started.uri
    version := started.version
    spec
    payload := leanSavePayload spec started.version textTraceHash
    fileProgress? := barrierProgress?
  }

private def handleSyncFileOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let path ←
      match req.pathArg with
      | .ok path => pure path
      | .error resp => return (resp, false)
    ensureRequestNotCancelled cancelRef?
    let path ← resolvePath ((← server.withState do pure (← get).config.root)) path
    let started ← startTrackedDiagnosticsBarrierIO server req path emitProgress? emitDiagnostic?
    propagatePendingCancellation started.session req.clientRequestId? cancelRef?
    let pending ← PendingRequest.awaitResult started.promise
    let barrierDecision :=
      decideSyncBarrier started.uri started.version started.priorProgress? pending.progress? pending.diagnostics
    let fileProgress? := barrierDecision.fileProgress?
    mergeFileProgressIfCurrent server started.session started.uri fileProgress?
    if barrierDecision.incomplete then
      let hints ← collectStaleDirectDepHintsIO server started.session started.uri started.version
      let targetPath := trackedPathLabel started.session.root started.uri
      return (syncBarrierIncompleteResponse started.uri started.version targetPath hints fileProgress?, false)
    server.withState do
      modifyCurrentSessionIfMatching started.session
        (fun current => markDocSyncedVersion current started.uri started.version)
    let saveReadiness ← fetchSyncSaveReadinessIO server started.session started.uri
    pure (syncFileSuccessResponse started.version pending.diagnostics saveReadiness fileProgress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleCloseOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Response × Bool) := do
  let path ←
    match req.pathArg with
    | .ok path => pure path
    | .error resp => return (resp, false)
  try
    if req.saveArtifacts?.getD false then
      let saved ← saveOleanIO server req path cancelRef? emitProgress? emitDiagnostic?
      finalizeSavedDoc server saved.session saved.uri saved.version saved.spec true
      pure (saveCompletedResponse saved true, false)
    else
      server.withState do
        match ← currentSession? req.backend with
        | some session =>
            let session ← closeFile session path
            updateSession session
            pure (Response.success (Json.mkObj [("closed", toJson true)]), false)
        | none =>
            pure (Response.success (Json.mkObj [("closed", toJson true)]), false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleRunAtOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let args ←
      match req.runAtArgs with
      | .ok args => pure args
      | .error resp => return (resp, false)
    ensureRequestNotCancelled cancelRef?
    let snapshot ← readRequestSyncSnapshot server req args.path
    let started ← server.withState do
      let session ← ensureSession req.backend
      startSyncedDocumentRequest session snapshot args.method
        (fun uri _ => Json.mkObj <|
          [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
          , ("position", toJson ({ line := args.line, character := args.character : Lsp.Position }))
          , ("text", toJson args.text)
          ] ++
          match req.storeHandle? with
          | some b => [("storeHandle", toJson b)]
          | none => [])
        trackedDocumentVersion
        (clientRequestId? := req.clientRequestId?)
        (emitProgress? := emitProgress?)
    let pending ← awaitSyncedDocumentRequestIO server req started cancelRef?
    pure (
      responseWithFileProgress
        (Response.success (wrapResultHandle started.session pending.result))
        pending.progress?,
      false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleRequestAtOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let args ←
      match req.requestAtArgs with
      | .ok args => pure args
      | .error resp => return (resp, false)
    ensureRequestNotCancelled cancelRef?
    let snapshot ← readRequestSyncSnapshot server req args.path
    let started ← server.withState do
      let session ← ensureSession req.backend
      startSyncedDocumentRequest session snapshot args.method
        (fun uri _ => Json.mergeObj args.extraParams <| Json.mkObj [
          ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
          ("position", toJson ({ line := args.line, character := args.character : Lsp.Position }))
        ])
        (trackedLeanDocumentVersion req.backend)
        (clientRequestId? := req.clientRequestId?)
        (emitProgress? := emitProgress?)
    let pending ← awaitSyncedDocumentRequestIO server req started cancelRef?
    pure (responseWithFileProgress (Response.success pending.result) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleSaveOleanOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Response × Bool) := do
  let path ←
    match req.pathArg with
    | .ok path => pure path
    | .error resp => return (resp, false)
  try
    let saved ← saveOleanIO server req path cancelRef? emitProgress? emitDiagnostic?
    finalizeSavedDoc server saved.session saved.uri saved.version saved.spec false
    pure (saveCompletedResponse saved false, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleGoalsOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let args ←
      match req.goalsArgs with
      | .ok args => pure args
      | .error resp => return (resp, false)
    if req.backend == .lean && req.text?.isSome then
      return (reqError "invalidParams" "lean goals does not accept speculative text; use lean-beam run-at for execution", false)
    ensureRequestNotCancelled cancelRef?
    let snapshot ← readRequestSyncSnapshot server req args.path
    let started ← server.withState do
      let session ← ensureSession req.backend
      let position : Lsp.Position := { line := args.line, character := args.character }
      startSyncedDocumentRequest session snapshot args.method
        (fun uri docState =>
          match req.backend with
          | .lean =>
              Json.mkObj [
                ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
                ("position", toJson position)
              ]
          | .rocq =>
              let fields :=
                [
                  ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier })),
                  ("position", toJson position),
                  ("mode", toJson (goalModeValue req.mode?)),
                  ("compact", toJson (req.compact?.getD false)),
                  ("pp_format", toJson (goalPpFormatValue req.ppFormat?))
                ] ++
                match req.text? with
                | some text => [("command", toJson text)]
                | none => []
              Json.mkObj fields)
        (trackedLeanDocumentVersion req.backend)
        (clientRequestId? := req.clientRequestId?)
        (emitProgress? := emitProgress?)
    let pending ← awaitSyncedDocumentRequestIO server req started cancelRef?
    pure (responseWithFileProgress (Response.success pending.result) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleTodoOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let args ←
      match req.todoArgs with
      | .ok args => pure args
      | .error resp => return (resp, false)
    ensureRequestNotCancelled cancelRef?
    let range : Lsp.Range := {
      start := { line := args.line, character := args.character }
      «end» := { line := args.endLine, character := args.endCharacter }
    }
    let snapshot ← readRequestSyncSnapshot server req args.path
    let started ← server.withState do
      let session ← ensureSession req.backend
      startSyncedDocumentRequest session snapshot args.method
        (fun uri _docState => Json.mkObj <|
          [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
          , ("range", toJson range)
          ] ++
          (match req.kinds? with
          | some kinds => [("kinds", toJson kinds)]
          | none => []) ++
          (match req.suggest? with
          | some suggest => [("suggest", toJson suggest)]
          | none => []))
        (trackedLeanDocumentVersion req.backend)
        (clientRequestId? := req.clientRequestId?)
        (emitProgress? := emitProgress?)
    let pending ← awaitSyncedDocumentRequestIO server req started cancelRef?
    pure (responseWithFileProgress (Response.success pending.result) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleRunWithOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let args ←
      match req.runWithArgs with
      | .ok args => pure args
      | .error resp => return (resp, false)
    ensureRequestNotCancelled cancelRef?
    let snapshot ← readRequestSyncSnapshot server req args.path
    let started ← server.withState do
      let session ← currentSessionForHandle req.backend
      let rawHandle ←
        match unwrapHandle session args.handle with
        | .ok raw => pure raw
        | .error err => throwBrokerFailure { code := .contentModified, message := err }
      startSyncedDocumentRequest session snapshot args.method
        (fun uri _ => Json.mkObj <|
          [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
          , ("handle", rawHandle)
          , ("text", toJson args.text)
          ] ++ (match req.storeHandle? with
          | some b => [("storeHandle", toJson b)]
          | none => []) ++
          (match req.linear? with
          | some b => [("linear", toJson b)]
          | none => []))
        trackedDocumentVersion
        (clientRequestId? := req.clientRequestId?)
        (emitProgress? := emitProgress?)
    let pending ← awaitSyncedDocumentRequestIO server req started cancelRef?
    pure (
      responseWithFileProgress
        (Response.success (wrapResultHandle started.session pending.result))
        pending.progress?,
      false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleReleaseOpIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    IO (Response × Bool) := do
  try
    let args ←
      match req.releaseArgs with
      | .ok args => pure args
      | .error resp => return (resp, false)
    ensureRequestNotCancelled cancelRef?
    let snapshot ← readRequestSyncSnapshot server req args.path
    let started ← server.withState do
      let session ← currentSessionForHandle req.backend
      let rawHandle ←
        match unwrapHandle session args.handle with
        | .ok raw => pure raw
        | .error err => throwBrokerFailure { code := .contentModified, message := err }
      startSyncedDocumentRequest session snapshot args.method
        (fun uri _ => Json.mkObj [
          ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
          ("handle", rawHandle)
        ])
        trackedDocumentVersion
        (clientRequestId? := req.clientRequestId?)
        (emitProgress? := emitProgress?)
    let pending ← awaitSyncedDocumentRequestIO server req started cancelRef?
    pure (responseWithFileProgress (Response.success pending.result) pending.progress?, false)
  catch e =>
    pure (responseForExceptionMessage e.toString, false)

private def handleRequestIO
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO (Response × Bool) := do
  match req.op with
  | .shutdown =>
      let resp ← server.withState do
        let state ← get
        for backend in [Backend.lean, Backend.rocq] do
          match (getBackendState state backend).session? with
          | some session => shutdownSession session
          | none => pure ()
        pure <| Response.success (Json.mkObj [("shutdown", toJson true)])
      pure (resp, true)
  | .stats =>
      pure (Response.success (← server.withState statsPayload), false)
  | .resetStats =>
      let now ← IO.monoNanosNow
      let resp ← server.withState do
        resetMetrics now
        pure <| Response.success (Json.mkObj [("reset", toJson true)])
      pure (resp, false)
  | .openDocs =>
      pure (Response.success (← server.withState openDocsPayload), false)
  | op =>
      match ← validateRequestRoot server req with
      | .error resp => pure (resp, false)
      | .ok _ =>
          match op with
          | .ensure =>
              let resp ←
                try
                  server.withState do
                    let session ← ensureSession req.backend
                    let payload := Json.mkObj [
                      ("backend", toJson req.backend),
                      ("root", toJson session.root.toString),
                      ("epoch", toJson session.epoch)
                    ]
                    pure <| Response.success payload
                catch e =>
                  pure <| reqError "internalError" e.toString
              pure (resp, false)
          | .cancel =>
              let targetClientRequestId ←
                match req.cancelRequestIdArg with
                | .ok targetClientRequestId => pure targetClientRequestId
                | .error resp => return (resp, false)
              let cancelled ← cancelActiveRequest server targetClientRequestId
              pure (Response.success (Json.mkObj [("cancelled", toJson cancelled)]), false)
          | .syncFile => handleSyncFileOpIO server req cancelRef? emitProgress? emitDiagnostic?
          | .close => handleCloseOpIO server req cancelRef? emitProgress? emitDiagnostic?
          | .runAt => handleRunAtOpIO server req cancelRef? emitProgress?
          | .requestAt => handleRequestAtOpIO server req cancelRef? emitProgress?
          | .deps => server.withState <| handleDepsOp req
          | .saveOlean => handleSaveOleanOpIO server req cancelRef? emitProgress? emitDiagnostic?
          | .goals => handleGoalsOpIO server req cancelRef? emitProgress?
          | .todo => handleTodoOpIO server req cancelRef? emitProgress?
          | .runWith => handleRunWithOpIO server req cancelRef? emitProgress?
          | .release => handleReleaseOpIO server req cancelRef? emitProgress?
          | .openDocs | .stats | .resetStats | .shutdown =>
              unreachable!

def ServerRuntime.dispatchRequest
    (server : ServerRuntime)
    (req : Request)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO (Response × Bool) := do
  let startedAt ← IO.monoNanosNow
  try
    let active? ←
      if requestTracksActiveRequest req.op then
        match ← ActiveRequestRegistry.register server.activeRequests req.clientRequestId? with
        | .ok active? => pure active?
        | .error err =>
            let resp := reqError "invalidParams" err
            let resp := resp.withClientRequestId req.clientRequestId?
            recordDispatchMetrics server req resp startedAt
            return (resp, false)
      else
        pure none
    try
      let (resp, shouldStop) ←
        handleRequestIO server req (active?.map (·.cancelRef)) emitProgress? emitDiagnostic?
      let resp := resp.withClientRequestId req.clientRequestId?
      recordDispatchMetrics server req resp startedAt
      pure (resp, shouldStop)
    finally
      ActiveRequestRegistry.unregister server.activeRequests active?
  catch e =>
    let resp := (Response.error "internalError" e.toString).withClientRequestId req.clientRequestId?
    recordDispatchMetrics server req resp startedAt
    pure (resp, false)

private def handleClient (server : ServerRuntime) (client : Transport.Connection) : IO Unit := do
  let clientRequestIdRef ← IO.mkRef (none : Option String)
  try
    let msg ← Transport.recvMsg client
    let req : Request ←
      match Json.parse msg with
      | .error err => throw <| IO.userError s!"invalid request json: {err}"
      | .ok json =>
          match fromJson? json with
          | .ok req => pure req
          | .error err => throw <| IO.userError s!"invalid request payload: {err}"
    clientRequestIdRef.set req.clientRequestId?
    let emitProgress : SyncFileProgress → IO Unit := fun progress =>
      Transport.sendMsg client (toJson (StreamMessage.mkFileProgress req.clientRequestId? progress)).compress
    let emitDiagnostic : StreamDiagnostic → IO Unit := fun diagnostic =>
      Transport.sendMsg client (toJson (StreamMessage.mkDiagnostic req.clientRequestId? diagnostic)).compress
    let (resp, shouldStop) ← server.dispatchRequest req (some emitProgress) (some emitDiagnostic)
    Transport.sendMsg client (toJson (StreamMessage.mkResponse resp)).compress
    if shouldStop then
      requestStop server
  catch e =>
    let resp := (Response.error "internalError" e.toString).withClientRequestId (← clientRequestIdRef.get)
    try
      Transport.sendMsg client (toJson (StreamMessage.mkResponse resp)).compress
    catch _ =>
      pure ()
  finally
    Transport.closeConnection client

private partial def acceptLoop (server : ServerRuntime) (listener : Transport.Listener) : IO Unit := do
  if ← server.stop.get then
    pure ()
  else
    let client ← Transport.accept listener
    if ← server.stop.get then
      Transport.closeConnection client
    else
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        try
          handleClient server client
        catch e =>
          IO.eprintln s!"broker client task failed: {e.toString}"
      acceptLoop server listener

private structure CliOptions where
  endpoint : Transport.Endpoint := .tcp 8765
  root? : Option String := none
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  rocqCmd? : Option String := none

private def parseNatArg (name value : String) : Except String Nat := do
  let some n := value.toNat?
    | throw s!"invalid {name} '{value}'"
  pure n

private def parsePortArg (value : String) : Except String UInt16 := do
  let port ← parseNatArg "port" value
  if port < UInt16.size then
    pure port.toUInt16
  else
    throw s!"port '{value}' is outside the supported range 0-65535"

private partial def parseCliOptions (opts : CliOptions) : List String → Except String CliOptions
  | [] => pure opts
  | "--socket" :: socketPath :: rest =>
      parseCliOptions { opts with endpoint := .unix (System.FilePath.mk socketPath) } rest
  | "--port" :: port :: rest => do
      let port ← parsePortArg port
      parseCliOptions { opts with endpoint := .tcp port } rest
  | "--root" :: root :: rest =>
      parseCliOptions { opts with root? := some root } rest
  | "--lean-cmd" :: leanCmd :: rest =>
      parseCliOptions { opts with leanCmd? := some leanCmd } rest
  | "--lean-plugin" :: leanPlugin :: rest =>
      parseCliOptions { opts with leanPlugin? := some leanPlugin } rest
  | "--rocq-cmd" :: rocqCmd :: rest =>
      parseCliOptions { opts with rocqCmd? := some rocqCmd } rest
  | arg :: _ =>
      throw s!"unexpected Beam daemon argument '{arg}'"

def main (args : List String) : IO Unit := do
  let opts ← IO.ofExcept <| parseCliOptions {} args
  let some root := opts.root?
    | throw <| IO.userError "missing Beam daemon --root PATH"
  let root ← Beam.resolveExistingPath <| System.FilePath.mk root
  let leanPlugin? ← opts.leanPlugin?.mapM (fun path => Beam.resolveExistingPath <| System.FilePath.mk path)
  let config : BrokerConfig := {
    root := root
    leanCmd? := opts.leanCmd?
    leanPlugin? := leanPlugin?
    rocqCmd? := opts.rocqCmd?
  }
  let listener ← Transport.bindAndListen opts.endpoint 16
  let startMonoNanos ← IO.monoNanosNow
  let runtime : ServerRuntime := {
    state := ← Std.Mutex.new { config := config, startMonoNanos := startMonoNanos }
    endpoint := opts.endpoint
    stop := ← IO.mkRef false
    activeRequests := ← ActiveRequestRegistry.create
  }
  try
    acceptLoop runtime listener
  finally
    Transport.closeListener listener

end Beam.Broker
