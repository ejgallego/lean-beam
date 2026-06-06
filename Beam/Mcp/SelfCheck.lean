/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Protocol
import Beam.Mcp.Stdio

open Lean

namespace Beam.Mcp.SelfCheck

structure Options where
  root? : Option String := none
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  beamCli? : Option String := none

private abbrev stdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  stderr := .piped

private def timeoutMs : Nat :=
  30000

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

private def childArgs (opts : Options) : List String :=
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

private def root (opts : Options) : IO System.FilePath := do
  match opts.root? with
  | some root => IO.FS.realPath <| System.FilePath.mk root
  | none => IO.FS.realPath (← IO.currentDir)

private def resolveFile (root : System.FilePath) (pathText : String) : IO System.FilePath := do
  let path := System.FilePath.mk pathText
  let path := if path.isAbsolute then path else root / path
  IO.FS.realPath path

private def readLine (stdout : IO.FS.Handle) : IO String := do
  let task ← IO.asTask stdout.getLine
  match ← waitForTaskWithTimeout task timeoutMs with
  | some line => pure <| Beam.Mcp.Stdio.stripLineEnding (← IO.ofExcept line)
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

private def expectResult (label : String) (json : Json) : IO Json := do
  match json.getObjVal? "error" with
  | .ok err =>
      throw <| IO.userError s!"{label} failed: {err.compress}"
  | .error _ =>
      requireObjVal label "result" json

private def childExitedMessage (child : IO.Process.Child stdio) : IO String := do
  let stderr ← child.stderr.readToEnd
  let stderr := stderr.trimAscii.toString
  if stderr.isEmpty then
    pure "lean-beam-mcp self-check child exited before responding"
  else
    pure s!"lean-beam-mcp self-check child exited before responding:\n{stderr}"

private def respondToRootsList (stdin : IO.FS.Handle) (request : Json) (root : System.FilePath) : IO Unit := do
  let requestId ← requireObjVal "roots/list request" "id" request
  Beam.Mcp.Stdio.writeJsonLineToHandle stdin <| Json.mkObj [
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

private partial def readResponse
    (child : IO.Process.Child stdio)
    (stdin stdout : IO.FS.Handle)
    (root : System.FilePath)
    (expectedId : Json) : IO Json := do
  if (← child.tryWait).isSome then
    throw <| IO.userError (← childExitedMessage child)
  let line ← readLine stdout
  if line.isEmpty then
    throw <| IO.userError "lean-beam-mcp self-check child closed stdout"
  let json ←
    match Json.parse line with
    | .ok json => pure json
    | .error err => throw <| IO.userError s!"lean-beam-mcp self-check child wrote invalid JSON: {err}: {line}"
  match json.getObjValAs? String "method" with
  | .ok "roots/list" =>
      respondToRootsList stdin json root
      readResponse child stdin stdout root expectedId
  | .ok method =>
      throw <| IO.userError s!"lean-beam-mcp self-check child sent unexpected request '{method}': {json.compress}"
  | .error _ =>
      let id ← requireObjVal "self-check response" "id" json
      if id == expectedId then
        pure json
      else
        throw <| IO.userError s!"expected self-check response id {expectedId.compress}, got {json.compress}"

private def sendInitialize (stdin : IO.FS.Handle) : IO Unit := do
  Beam.Mcp.Stdio.writeJsonLineToHandle stdin <| Json.mkObj [
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

private def sendInitialized (stdin : IO.FS.Handle) : IO Unit := do
  Beam.Mcp.Stdio.writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson "notifications/initialized")
  ]

private def sendSync (stdin : IO.FS.Handle) (pathText : String) : IO Unit := do
  Beam.Mcp.Stdio.writeJsonLineToHandle stdin <| Json.mkObj [
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

private def sendShutdown (stdin : IO.FS.Handle) : IO Unit := do
  Beam.Mcp.Stdio.writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (3 : Nat)),
    ("method", toJson "shutdown")
  ]

private def terminateChild (child : IO.Process.Child stdio) : IO Unit := do
  if (← child.tryWait).isNone then
    try
      child.kill
    catch _ =>
      pure ()
  try
    discard <| child.wait
  catch _ =>
    pure ()

def run (opts : Options) (pathText : String) : IO Unit := do
  let root ← root opts
  let resolvedPath ← resolveFile root pathText
  let appPath ← IO.appPath
  let child ← IO.Process.spawn {
    toStdioConfig := stdio
    cmd := appPath.toString
    args := (childArgs opts).toArray
    cwd := root.toString
  }
  try
    sendInitialize child.stdin
    let init ← expectResult "initialize" =<<
      readResponse child child.stdin child.stdout root (toJson (1 : Nat))
    let negotiated ← requireObjValAs (α := String) "initialize result" "protocolVersion" init
    if negotiated != protocolVersion then
      throw <| IO.userError s!"server negotiated MCP protocol {negotiated}, expected {protocolVersion}"
    sendInitialized child.stdin
    sendSync child.stdin pathText
    let sync ← expectResult "lean_sync" =<<
      readResponse child child.stdin child.stdout root (toJson (2 : Nat))
    match sync.getObjVal? "isError" with
    | .ok (.bool true) =>
        throw <| IO.userError s!"lean_sync returned an MCP tool error: {sync.compress}"
    | _ => pure ()
    let structured ← requireObjVal "lean_sync result" "structuredContent" sync
    discard <| requireObjVal "lean_sync structuredContent" "file_progress" structured
    sendShutdown child.stdin
    let shutdown ← expectResult "shutdown" =<<
      readResponse child child.stdin child.stdout root (toJson (3 : Nat))
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
    terminateChild child
    throw e

end Beam.Mcp.SelfCheck
