/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Mcp.Protocol

open Lean

namespace Beam.Mcp.Server

structure ProtocolState where
  initializeComplete : Bool := false
  initializedNotificationSeen : Bool := false
  clientSupportsRoots : Bool := false
  root? : Option System.FilePath := none
  rootError? : Option String := none
  runtime? : Option Beam.Broker.ServerRuntime := none

def ProtocolState.create (root? : Option System.FilePath := none) : IO (IO.Ref ProtocolState) :=
  IO.mkRef { root? }

structure Options where
  root? : Option String := none
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  beamCli? : Option String := none
  selfCheckPath? : Option String := none

private def usage : String :=
  String.intercalate "\n" [
    "usage: lean-beam-mcp [--root PATH] [--beam-cli PATH] [--lean-cmd CMD] [--lean-plugin PATH]",
    "       lean-beam-mcp [--root PATH] [--beam-cli PATH] --self-check <lean-file>",
    "",
    "Runs the experimental Lean Beam MCP server over newline-delimited JSON-RPC on stdio.",
    "When --root is omitted, the server discovers exactly one project root via MCP roots/list.",
    "--self-check starts a child MCP server, supplies the root through roots/list, and calls lean_sync.",
    "The installed wrapper passes --beam-cli automatically so project-specific Lean bundles resolve on demand.",
    "Only curated Lean tools are exposed; raw LSP and broker escape hatches are intentionally absent."
  ]

private partial def parseOptions (opts : Options) : List String → Except String Options
  | [] => pure opts
  | "--root" :: root :: rest =>
      parseOptions { opts with root? := some root } rest
  | "--lean-cmd" :: leanCmd :: rest =>
      parseOptions { opts with leanCmd? := some leanCmd } rest
  | "--lean-plugin" :: leanPlugin :: rest =>
      parseOptions { opts with leanPlugin? := some leanPlugin } rest
  | "--beam-cli" :: beamCli :: rest =>
      parseOptions { opts with beamCli? := some beamCli } rest
  | "--self-check" :: path :: rest =>
      parseOptions { opts with selfCheckPath? := some path } rest
  | "-h" :: _ | "--help" :: _ =>
      throw usage
  | arg :: _ =>
      throw s!"unexpected lean-beam-mcp argument '{arg}'\n\n{usage}"

private structure LeanRuntimeConfig where
  leanCmd : String
  leanPlugin : System.FilePath

private def setupError (message : String) : RpcError :=
  RpcError.invalidRequest s!"could not set up Lean Beam MCP runtime: {message}"

private def processOutputSummary (stdout stderr : String) : String :=
  let stderr := stderr.trimAscii.toString
  let stdout := stdout.trimAscii.toString
  if !stderr.isEmpty then
    stderr
  else if !stdout.isEmpty then
    stdout
  else
    "(no output)"

private def parseCliMcpConfig (text : String) : Except String LeanRuntimeConfig := do
  let json ← Json.parse text
  let leanCmd ← json.getObjValAs? String "lean_cmd"
  let leanPluginText ← json.getObjValAs? String "lean_plugin"
  pure { leanCmd, leanPlugin := System.FilePath.mk leanPluginText }

private def resolveFromBeamCli (beamCli : String) (root : System.FilePath) : IO (Except String LeanRuntimeConfig) := do
  let out ← IO.Process.output {
    cmd := beamCli
    args := #["--root", root.toString, "mcp-config"]
  }
  if out.exitCode != 0 then
    pure <| .error s!"{beamCli} --root {root} mcp-config failed: {processOutputSummary out.stdout out.stderr}"
  else
    match parseCliMcpConfig out.stdout with
    | .error err => pure <| .error s!"{beamCli} mcp-config returned invalid JSON: {err}"
    | .ok config => do
        let plugin ← IO.FS.realPath config.leanPlugin
        pure <| .ok { config with leanPlugin := plugin }

private def resolveLeanRuntime (opts : Options) (root : System.FilePath) : IO (Except RpcError LeanRuntimeConfig) := do
  let explicitPlugin? ←
    try
      opts.leanPlugin?.mapM (fun path => IO.FS.realPath <| System.FilePath.mk path)
    catch e =>
      return .error <| setupError s!"--lean-plugin does not resolve to a file: {e}"
  match opts.leanCmd?, explicitPlugin? with
  | some leanCmd, some leanPlugin =>
      pure <| .ok { leanCmd, leanPlugin }
  | _, _ =>
      match opts.beamCli? with
      | none =>
          pure <| .error <| setupError
            "use the installed lean-beam-mcp wrapper, pass --beam-cli PATH, or pass both --lean-cmd CMD and --lean-plugin PATH"
      | some beamCli =>
          match ← resolveFromBeamCli beamCli root with
          | .error err => pure <| .error <| setupError err
          | .ok resolved =>
              pure <| .ok {
                leanCmd := opts.leanCmd?.getD resolved.leanCmd
                leanPlugin := explicitPlugin?.getD resolved.leanPlugin
              }

private def mkBrokerConfig (opts : Options) (root : System.FilePath) : IO (Except RpcError Beam.Broker.BrokerConfig) := do
  let root ←
    try
      IO.FS.realPath root
    catch e =>
      return .error <| setupError s!"project root does not resolve: {e}"
  let runtime ← resolveLeanRuntime opts root
  match runtime with
  | .error err => pure <| .error err
  | .ok runtime =>
      pure <| .ok {
        root := root
        leanCmd? := some runtime.leanCmd
        leanPlugin? := some runtime.leanPlugin
      }

def stripLineEnding (line : String) : String :=
  let line :=
    if !line.isEmpty && line.back == '\n' then
      line.dropEnd 1 |>.copy
    else
      line
  if !line.isEmpty && line.back == '\r' then
    line.dropEnd 1 |>.copy
  else
    line

private def writeJsonLineTo (stream : IO.FS.Stream) (json : Json) : IO Unit := do
  stream.putStr (json.compress ++ "\n")
  stream.flush

private def writeJsonLineToHandle (handle : IO.FS.Handle) (json : Json) : IO Unit := do
  handle.putStr (json.compress ++ "\n")
  handle.flush

private def writeJsonLine (json : Json) : IO Unit := do
  let stdout ← IO.getStdout
  writeJsonLineTo stdout json

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

private def invalidRequestId (json : Json) : Json :=
  match json.getObjVal? "id" with
  | .ok id =>
      if validRequestId id then id else Json.null
  | .error _ => Json.null

private def brokerClientRequestId (req : Request) : String :=
  s!"mcp:{requestIdLabel req.id}"

private def rootsUnsupportedMessage : String :=
  "MCP client did not advertise roots; start lean-beam-mcp with --root PATH or enable the client's roots capability"

private def selectClientRoot (roots : Array ClientRoot) : Except String System.FilePath := do
  if roots.size == 0 then
    throw "MCP client returned no roots; start lean-beam-mcp with --root PATH or configure exactly one project root"
  else if roots.size > 1 then
    throw "MCP client returned multiple roots; start lean-beam-mcp with --root PATH until multi-root selection is supported"
  else
    let root := roots[0]!
    match System.Uri.fileUriToPath? root.uri with
    | some path => pure path
    | none => throw s!"MCP client root URI must be a file:// URI, got {root.uri}"

private partial def requestClientRoot (stdin : IO.FS.Stream) : IO (Except String System.FilePath) := do
  try
    writeJsonLine rootsListRequest
    let rec waitForResponse : IO (Except String System.FilePath) := do
      let line := stripLineEnding (← stdin.getLine)
      if line.isEmpty then
        pure <| .error "MCP client closed stdin before answering roots/list"
      else
        match Json.parse line with
        | .error err =>
            pure <| .error s!"MCP client roots/list response is not valid JSON: {err}"
        | .ok json =>
            match json.getObjVal? "method" with
            | .ok _ =>
                match Incoming.fromJson? json with
                | .ok (.request req) =>
                    writeJsonLine <|
                      errorResponse req.id <|
                        RpcError.invalidRequest "cannot process client request while waiting for roots/list response"
                    waitForResponse
                | .ok (.notification notification) =>
                    if notification.method == "exit" then
                      pure <| .error "MCP client exited before answering roots/list"
                    else
                      waitForResponse
                | .error err =>
                    pure <| .error err
            | .error _ =>
                match parseRootsListResponse json with
                | .error err => pure <| .error err
                | .ok result =>
                    match selectClientRoot result.roots with
                    | .error err => pure <| .error err
                    | .ok root =>
                        let root ← IO.FS.realPath root
                        pure <| .ok root
    waitForResponse
  catch e =>
    pure <| .error e.toString

private def ensureRoot
    (state : IO.Ref ProtocolState)
    (stdin : IO.FS.Stream) : IO (Except RpcError System.FilePath) := do
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
              requestClientRoot stdin
            else
              pure <| .error rootsUnsupportedMessage
          match root? with
          | .error err =>
              state.modify fun state => { state with rootError? := some err }
              pure <| .error <| RpcError.invalidRequest err
          | .ok root =>
              state.modify fun state => { state with root? := some root }
              pure <| .ok root

private def ensureRuntime
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream) : IO (Except RpcError (Beam.Broker.ServerRuntime × System.FilePath)) := do
  let currentState ← state.get
  match currentState.runtime?, currentState.root? with
  | some runtime, some root =>
      pure <| .ok (runtime, root)
  | _, _ =>
      match ← ensureRoot state stdin with
      | .error err => pure <| .error err
      | .ok root =>
          match ← mkBrokerConfig opts root with
          | .error err =>
              state.modify fun state => { state with rootError? := some err.message }
              pure <| .error err
          | .ok config =>
              try
                let runtime ← Beam.Broker.ServerRuntime.create config
                state.modify fun state => { state with root? := some config.root, runtime? := some runtime }
                pure <| .ok (runtime, config.root)
              catch e =>
                let err := setupError e.toString
                state.modify fun state => { state with rootError? := some err.message }
                pure <| .error err

private def brokerRequestForTool
    (root : System.FilePath)
    (params : CallToolParams)
    (clientRequestId : String) : Except String Beam.Broker.Request := do
  let req ← params.name.toBrokerRequest root.toString params.arguments
  pure { req with clientRequestId? := some clientRequestId }

private def handleToolCall
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request) : IO (Except RpcError Json) := do
  let params ←
    match parseCallToolParams req.params? with
    | .ok params => pure params
    | .error err => return .error <| RpcError.invalidParams err
  let root ←
    match ← ensureRoot state stdin with
    | .ok root => pure root
    | .error err => return .error err
  let brokerReq ←
    match brokerRequestForTool root params (brokerClientRequestId req) with
    | .ok brokerReq => pure brokerReq
    | .error err => return .ok <| callToolErrorResult <| ToolError.invalidInput err
  let (runtime, _root) ←
    match ← ensureRuntime state opts stdin with
    | .ok runtimeAndRoot => pure runtimeAndRoot
    | .error err => return .error err
  let (brokerResp, _) ← runtime.dispatchRequest brokerReq
  match normalizeBrokerResponse params.name brokerResp with
  | .ok result =>
      pure <| .ok <| callToolResult result
  | .error err =>
      pure <| .ok <| callToolErrorResult err

def handleRequest
    (state : IO.Ref ProtocolState)
    (opts : Options)
    (stdin : IO.FS.Stream)
    (req : Request) : IO (Json × Bool) := do
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
        match req.method with
        | "tools/list" =>
            pure (successResponse req.id toolsListResult, false)
        | "tools/call" =>
            match ← handleToolCall state opts stdin req with
            | .ok result => pure (successResponse req.id result, false)
            | .error err => pure (errorResponse req.id err, false)
        | _ =>
            unreachable!
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
    (json : Json) : IO (Option Json × Bool) := do
  match Incoming.fromJson? json with
  | .ok (.request req) =>
      let (resp, stop) ← handleRequest state opts stdin req
      pure (some resp, stop)
  | .ok (.notification notification) =>
      let stop ← handleNotification state notification
      pure (none, stop)
  | .error err =>
      pure (some <| errorResponse (invalidRequestId json) (RpcError.invalidRequest err), false)

private abbrev selfCheckStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  stderr := .piped

private def selfCheckTimeoutMs : Nat :=
  30000

private def optsForSelfCheckChild (opts : Options) : List String :=
  let args := []
  let args :=
    match opts.beamCli? with
    | some beamCli => args ++ ["--beam-cli", beamCli]
    | none => args
  let args :=
    match opts.leanCmd? with
    | some leanCmd => args ++ ["--lean-cmd", leanCmd]
    | none => args
  let args :=
    match opts.leanPlugin? with
    | some leanPlugin => args ++ ["--lean-plugin", leanPlugin]
    | none => args
  args

private def selfCheckRoot (opts : Options) : IO System.FilePath := do
  match opts.root? with
  | some root => IO.FS.realPath <| System.FilePath.mk root
  | none => IO.FS.realPath (← IO.currentDir)

private def resolveSelfCheckFile (root : System.FilePath) (pathText : String) : IO System.FilePath := do
  let path := System.FilePath.mk pathText
  let path := if path.isAbsolute then path else root / path
  IO.FS.realPath path

private def readSelfCheckLine (stdout : IO.FS.Handle) : IO String := do
  let task ← IO.asTask stdout.getLine
  match ← waitForTaskWithTimeout task selfCheckTimeoutMs with
  | some line => pure <| stripLineEnding (← IO.ofExcept line)
  | none => throw <| IO.userError "timed out waiting for lean-beam-mcp self-check response"

private def throwJsonFieldError (label field : String) (json : Json) (err : String) : IO α :=
  throw <| IO.userError s!"{label}: missing or invalid '{field}': {err}; response: {json.compress}"

private def requireObjVal (label field : String) (json : Json) : IO Json := do
  match json.getObjVal? field with
  | .ok value => pure value
  | .error err => throwJsonFieldError label field json err

private def requireObjValAs [FromJson α] (label field : String) (json : Json) : IO α := do
  match json.getObjValAs? α field with
  | .ok value => pure value
  | .error err => throwJsonFieldError label field json err

private def expectSelfCheckResult (label : String) (json : Json) : IO Json := do
  match json.getObjVal? "error" with
  | .ok err =>
      throw <| IO.userError s!"{label} failed: {err.compress}"
  | .error _ =>
      requireObjVal label "result" json

private def childExitedMessage (child : IO.Process.Child selfCheckStdio) : IO String := do
  let stderr ← child.stderr.readToEnd
  let stderr := stderr.trimAscii.toString
  if stderr.isEmpty then
    pure "lean-beam-mcp self-check child exited before responding"
  else
    pure s!"lean-beam-mcp self-check child exited before responding:\n{stderr}"

private def respondToSelfCheckRoots (stdin : IO.FS.Handle) (request : Json) (root : System.FilePath) : IO Unit := do
  let requestId ← requireObjVal "roots/list request" "id" request
  writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", requestId),
    ("result", Json.mkObj [
      ("roots", toJson #[
        Json.mkObj [
          ("uri", toJson (System.Uri.pathToUri root : String)),
          ("name", toJson "lean-beam-self-check")
        ]
      ])
    ])
  ]

private partial def readSelfCheckResponse
    (child : IO.Process.Child selfCheckStdio)
    (stdin stdout : IO.FS.Handle)
    (root : System.FilePath)
    (expectedId : Json) : IO Json := do
  if (← child.tryWait).isSome then
    throw <| IO.userError (← childExitedMessage child)
  let line ← readSelfCheckLine stdout
  if line.isEmpty then
    throw <| IO.userError "lean-beam-mcp self-check child closed stdout"
  let json ←
    match Json.parse line with
    | .ok json => pure json
    | .error err => throw <| IO.userError s!"lean-beam-mcp self-check child wrote invalid JSON: {err}: {line}"
  match json.getObjValAs? String "method" with
  | .ok "roots/list" =>
      respondToSelfCheckRoots stdin json root
      readSelfCheckResponse child stdin stdout root expectedId
  | .ok method =>
      throw <| IO.userError s!"lean-beam-mcp self-check child sent unexpected request '{method}': {json.compress}"
  | .error _ =>
      let id ← requireObjVal "self-check response" "id" json
      if id == expectedId then
        pure json
      else
        throw <| IO.userError s!"expected self-check response id {expectedId.compress}, got {json.compress}"

private def sendSelfCheckInitialize (stdin : IO.FS.Handle) : IO Unit := do
  writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (1 : Nat)),
    ("method", toJson "initialize"),
    ("params", Json.mkObj [
      ("protocolVersion", toJson protocolVersion),
      ("capabilities", Json.mkObj [
        ("roots", Json.mkObj [
          ("listChanged", toJson false)
        ])
      ]),
      ("clientInfo", Json.mkObj [
        ("name", toJson "lean-beam-mcp-self-check"),
        ("version", toJson serverVersion)
      ])
    ])
  ]

private def sendSelfCheckInitialized (stdin : IO.FS.Handle) : IO Unit := do
  writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson "notifications/initialized")
  ]

private def sendSelfCheckSync (stdin : IO.FS.Handle) (pathText : String) : IO Unit := do
  writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (2 : Nat)),
    ("method", toJson "tools/call"),
    ("params", Json.mkObj [
      ("name", toJson ToolName.leanSync),
      ("arguments", Json.mkObj [
        ("path", toJson pathText)
      ])
    ])
  ]

private def sendSelfCheckShutdown (stdin : IO.FS.Handle) : IO Unit := do
  writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (3 : Nat)),
    ("method", toJson "shutdown")
  ]

private def terminateSelfCheckChild (child : IO.Process.Child selfCheckStdio) : IO Unit := do
  if (← child.tryWait).isNone then
    try
      child.kill
    catch _ =>
      pure ()
  try
    discard <| child.wait
  catch _ =>
    pure ()

private def runSelfCheck (opts : Options) (pathText : String) : IO Unit := do
  let root ← selfCheckRoot opts
  let resolvedPath ← resolveSelfCheckFile root pathText
  let appPath ← IO.appPath
  let child ← IO.Process.spawn {
    toStdioConfig := selfCheckStdio
    cmd := appPath.toString
    args := (optsForSelfCheckChild opts).toArray
    cwd := root.toString
  }
  try
    sendSelfCheckInitialize child.stdin
    let init ← expectSelfCheckResult "initialize" =<<
      readSelfCheckResponse child child.stdin child.stdout root (toJson (1 : Nat))
    let negotiated ← requireObjValAs (α := String) "initialize result" "protocolVersion" init
    if negotiated != protocolVersion then
      throw <| IO.userError s!"server negotiated MCP protocol {negotiated}, expected {protocolVersion}"
    sendSelfCheckInitialized child.stdin
    sendSelfCheckSync child.stdin pathText
    let sync ← expectSelfCheckResult "lean_sync" =<<
      readSelfCheckResponse child child.stdin child.stdout root (toJson (2 : Nat))
    match sync.getObjVal? "isError" with
    | .ok (.bool true) =>
        throw <| IO.userError s!"lean_sync returned an MCP tool error: {sync.compress}"
    | _ => pure ()
    let structured ← requireObjVal "lean_sync result" "structuredContent" sync
    discard <| requireObjVal "lean_sync structuredContent" "file_progress" structured
    sendSelfCheckShutdown child.stdin
    let shutdown ← expectSelfCheckResult "shutdown" =<<
      readSelfCheckResponse child child.stdin child.stdout root (toJson (3 : Nat))
    unless shutdown == Json.mkObj [] do
      throw <| IO.userError s!"unexpected shutdown result: {shutdown.compress}"
    let exitCode ← child.wait
    if exitCode != 0 then
      let stderr ← child.stderr.readToEnd
      throw <| IO.userError s!"lean-beam-mcp self-check child exited with code {exitCode}\n{stderr}"
    let stderr ← child.stderr.readToEnd
    unless stderr.trimAscii.toString.isEmpty do
      throw <| IO.userError s!"lean-beam-mcp self-check child wrote stderr:\n{stderr}"
    IO.println "Lean Beam MCP self-check passed"
    IO.println s!"  root: {root}"
    IO.println s!"  file: {resolvedPath}"
    IO.println s!"  root discovery: roots/list"
    IO.println s!"  protocol: {protocolVersion}"
    IO.println "  lean_sync: ok"
  catch e =>
    terminateSelfCheckChild child
    throw e

partial def runStdio (opts : Options) (root? : Option System.FilePath) : IO Unit := do
  let stdin ← IO.getStdin
  let state ← ProtocolState.create root?
  let rec loop : IO Unit := do
    let line := stripLineEnding (← stdin.getLine)
    if line.isEmpty then
      pure ()
    else
      match Json.parse line with
      | .error err =>
          writeJsonLine <| errorResponse Json.null (RpcError.parseError err)
          loop
      | .ok json =>
          let (response?, stop) ← handleJson state opts stdin json
          match response? with
          | some response => writeJsonLine response
          | none => pure ()
          unless stop do
            loop
  loop

def main (args : List String) : IO Unit := do
  let opts ←
    match parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  match opts.selfCheckPath? with
  | some path =>
      runSelfCheck opts path
  | none =>
      let root? ← opts.root?.mapM (fun root => IO.FS.realPath <| System.FilePath.mk root)
      runStdio opts root?

end Beam.Mcp.Server
