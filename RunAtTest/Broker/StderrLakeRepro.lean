/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake.Build.Job.Basic
import Lake.Build.Run
import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.Load.Workspace
import Lean
import Lean.Data.Lsp.Communication
import Lean.Data.Lsp.TextSync
import Beam.Broker.Backend.Lean
import Beam.Broker.Server
import RunAt.Lib.NativeLib

open Lean
open Lean.Lsp
open System
open Lake

namespace RunAtTest.Broker.StderrLakeRepro

abbrev childStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  stderr := .piped

private def debugLog (message : String) : IO Unit := do
  IO.eprintln s!"beam-debug: {message}"

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

private def waitForPromiseWithTimeout
    (promise : IO.Promise Unit)
    (timeoutMs : Nat) : IO Bool := do
  let task ← IO.asTask do
    let some _ ← IO.wait promise.result?
      | return false
    pure true
  match ← waitForTaskWithTimeout task timeoutMs with
  | some (.ok seen) => pure seen
  | some (.error _) => pure false
  | none => pure false

private def computeLakeEnv : IO Lake.Env := do
  let elan? ← Lake.findElanInstall?
  let lean? ← Lake.findLeanCmdInstall? "lean"
  let (lean?, lake?) ←
    match lean? with
    | some lean => pure (some lean, some (Lake.LakeInstall.ofLean lean))
    | none =>
        let (_, lean?, lake?) ← Lake.findInstall?
        pure (lean?, lake?)
  let some lean := lean?
    | throw <| IO.userError "could not locate Lean installation"
  let some lake := lake?
    | throw <| IO.userError "could not locate Lake installation"
  match ← (Lake.Env.compute lake lean elan?).toBaseIO with
  | .ok env => pure env
  | .error err => throw <| IO.userError s!"failed to compute Lake environment: {err}"

private def makeWorkspace : IO FilePath := do
  let root := FilePath.mk s!"/tmp/beam-stderr-lake-repro-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "lakefile.toml") <| String.intercalate "\n" [
    "name = \"stderr_lake_repro\"",
    "",
    "[[lean_lib]]",
    "name = \"StderrLakeRepro\"",
    ""
  ]
  IO.FS.writeFile (root / "StderrLakeRepro.lean") "def stderrLakeReproVal : Nat := 1\n"
  pure root

private def loadWorkspace (root : FilePath) : IO Workspace := do
  let lakeEnv ← computeLakeEnv
  let relConfigFile := FilePath.mk "lakefile.toml"
  let loadConfig : LoadConfig := {
    lakeEnv := lakeEnv
    wsDir := root
    relPkgDir := FilePath.mk "."
    pkgDir := root
    relConfigFile := relConfigFile
    configFile := root / relConfigFile
    updateToolchain := false
  }
  let (ws?, log) ← LoggerIO.captureLog <| Lake.loadWorkspace loadConfig
  let some ws := ws?
    | throw <| IO.userError <|
        "failed to load temporary Lake workspace\n" ++
        String.intercalate "\n" (log.entries.map (·.toString)).toList
  pure ws

private partial def awaitInitializeResponse (stdout : IO.FS.Stream) : IO Unit := do
  let msg ← stdout.readLspMessage
  match msg with
  | .response id _ =>
      if id == 0 then
        pure ()
      else
        throw <| IO.userError s!"unexpected response id {id} before initialize completed"
  | .responseError id _code message _ =>
      if id == 0 then
        throw <| IO.userError s!"initialize failed: {message}"
      else
        throw <| IO.userError s!"unexpected response error id {id} before initialize completed: {message}"
  | .request .. =>
      awaitInitializeResponse stdout
  | .notification .. =>
      awaitInitializeResponse stdout

private def spawnSleep (root : FilePath) : IO (IO.Process.Child childStdio) :=
  IO.Process.spawn {
    toStdioConfig := childStdio
    cmd := "/bin/sleep"
    args := #["120"]
    cwd := root.toString
  }

private def pluginPath : IO FilePath := do
  IO.FS.realPath <| RunAt.Lib.pluginSharedLibPath (FilePath.mk ".lake/build/lib")

private def spawnLeanServer (root : FilePath) (usePlugin : Bool := false) :
    IO (IO.Process.Child childStdio) := do
  let pluginArgs ←
    if usePlugin then
      let plugin ← pluginPath
      pure #[s!"--plugin={plugin}", "-Dexperimental.module=true"]
    else
      pure #[]
  IO.Process.spawn {
    toStdioConfig := childStdio
    cmd := "lean"
    args := #["--server"] ++ pluginArgs ++ #["-DstderrAsMessages=false"]
    cwd := root.toString
  }

private def spawnChild (kind : String) (root : FilePath) : IO (IO.Process.Child childStdio) := do
  match kind with
  | "sleep" => spawnSleep root
  | "lean-server"
  | "lean-session"
  | "lean-open" =>
      spawnLeanServer root
  | "lean-plugin-open" =>
      spawnLeanServer root (usePlugin := true)
  | other =>
      throw <| IO.userError s!"unknown child kind '{other}', expected sleep, lean-server, lean-session, lean-open, or lean-plugin-open"

private def baseChildKind (kind : String) : String :=
  if kind == "sleep-dual" || kind == "sleep-dual-dedicated" then
    "sleep"
  else if kind == "lean-server-dual" then
    "lean-server"
  else if kind == "lean-open-no-stderr" ||
      kind == "lean-open-no-stdout" ||
      kind == "lean-open-no-readers" then
    "lean-open"
  else if kind == "lean-session-no-stderr" ||
      kind == "lean-session-no-stdout" ||
      kind == "lean-session-no-readers" ||
      kind == "lean-session-dedicated" then
    "lean-session"
  else
    kind

private def dedicatedReaderKind (kind : String) : Bool :=
  kind == "sleep-dual-dedicated" || kind == "lean-session-dedicated"

private def readerPriority (kind : String) : Task.Priority :=
  if dedicatedReaderKind kind then Task.Priority.dedicated else Task.Priority.default

private def shouldStartStderrDrain (kind : String) : Bool :=
  kind != "lean-open-no-stderr" &&
    kind != "lean-open-no-readers" &&
    kind != "lean-session-no-stderr" &&
    kind != "lean-session-no-readers"

private def shouldStartStdoutReader (kind : String) : Bool :=
  kind != "lean-open-no-stdout" &&
    kind != "lean-open-no-readers" &&
    kind != "lean-session-no-stdout" &&
    kind != "lean-session-no-readers"

private def shouldStartStdoutDrain (kind : String) : Bool :=
  kind == "sleep-dual" || kind == "sleep-dual-dedicated" || kind == "lean-server-dual"

private def startStderrDrain (kind : String) (child : IO.Process.Child childStdio) : IO Unit := do
  let _ ← IO.asTask (prio := readerPriority kind) do
    try
      debugLog s!"stderr drain start kind={kind} pid={child.pid.toNat}"
      let stderr ← child.stderr.readToEnd
      debugLog s!"stderr drain eof kind={kind} bytes={stderr.length}"
      unless stderr.trimAscii.toString.isEmpty do
        IO.eprintln s!"beam-debug: child stderr kind={kind}:\n{stderr}"
    catch e =>
      debugLog s!"stderr drain failed kind={kind}: {e.toString}"

private def startStdoutDrain (kind : String) (child : IO.Process.Child childStdio) : IO Unit := do
  let _ ← IO.asTask (prio := readerPriority kind) do
    try
      debugLog s!"stdout drain start kind={kind} pid={child.pid.toNat}"
      let stdout ← child.stdout.readToEnd
      debugLog s!"stdout drain eof kind={kind} bytes={stdout.length}"
    catch e =>
      debugLog s!"stdout drain failed kind={kind}: {e.toString}"

private def startStdoutReader
    (kind : String)
    (child : IO.Process.Child childStdio)
    (diagSeen? : Option (IO.Promise Unit)) : IO Unit := do
  let stdout := IO.FS.Stream.ofHandle child.stdout
  let _ ← IO.asTask (prio := readerPriority kind) do
    try
      debugLog s!"stdout reader start kind={kind} pid={child.pid.toNat}"
      repeat
        let msg ← stdout.readLspMessage
        match msg with
        | .notification method _ =>
            debugLog s!"stdout reader notification kind={kind} method={method}"
            if method == "textDocument/publishDiagnostics" then
              if let some diagSeen := diagSeen? then
                try
                  diagSeen.resolve ()
                catch _ =>
                  pure ()
        | .request .. =>
            debugLog s!"stdout reader request kind={kind}"
        | .response id _ =>
            debugLog s!"stdout reader response kind={kind} id={id}"
        | .responseError id _code message _ =>
            debugLog s!"stdout reader responseError kind={kind} id={id}: {message}"
    catch e =>
      debugLog s!"stdout reader failed kind={kind} pid={child.pid.toNat}: {e.toString}"

private def initializeLeanSession
    (kind : String)
    (root : FilePath)
    (child : IO.Process.Child childStdio)
    (diagSeen? : Option (IO.Promise Unit))
    (startReader : Bool := true) : IO Unit := do
  let stdin := IO.FS.Stream.ofHandle child.stdin
  let stdout := IO.FS.Stream.ofHandle child.stdout
  debugLog s!"lean session initialize request start kind={kind} pid={child.pid.toNat}"
  stdin.writeLspRequest ({
    id := 0
    method := "initialize"
    param := Beam.Broker.Backend.Lean.initializeParams root
    : Lean.JsonRpc.Request Json
  })
  awaitInitializeResponse stdout
  stdin.writeLspNotification ({
    method := "initialized"
    param := Json.mkObj []
    : Lean.JsonRpc.Notification Json
  })
  debugLog s!"lean session initialized kind={kind} pid={child.pid.toNat}"
  if startReader then
    startStdoutReader kind child diagSeen?

private def openLeanDocument
    (kind : String)
    (root : FilePath)
    (child : IO.Process.Child childStdio) : IO Unit := do
  let path := root / "StderrLakeRepro.lean"
  let text ← IO.FS.readFile path
  let stdin := IO.FS.Stream.ofHandle child.stdin
  stdin.writeLspNotification ({
    method := "textDocument/didOpen"
    param := toJson ({
      textDocument := {
        uri := (System.Uri.pathToUri path : DocumentUri)
        languageId := "lean"
        version := 1
        text
      }
      : DidOpenTextDocumentParams
    })
    : Lean.JsonRpc.Notification Json
  })
  debugLog s!"didOpen sent kind={kind} path={path}"

private def prepareChild (kind : String) (root : FilePath) : IO (IO.Process.Child childStdio) := do
  let childKind := baseChildKind kind
  let child ← spawnChild childKind root
  if shouldStartStderrDrain kind then
    startStderrDrain kind child
  if shouldStartStdoutDrain kind then
    startStdoutDrain kind child
  let shouldInitialize :=
    childKind == "lean-session" || childKind == "lean-open" || childKind == "lean-plugin-open"
  let shouldOpen := childKind == "lean-open" || childKind == "lean-plugin-open"
  let startStdout := shouldStartStdoutReader kind
  let diagSeen? ←
    if shouldOpen && startStdout then
      pure (some (← IO.Promise.new))
    else
      pure none
  if shouldInitialize then
    initializeLeanSession kind root child diagSeen? (startReader := startStdout)
  if shouldOpen then
    openLeanDocument kind root child
    if let some diagSeen := diagSeen? then
      let seen ← waitForPromiseWithTimeout diagSeen 2000
      debugLog s!"didOpen diagnostics wait kind={kind} seen={seen}"
  pure child

private def cleanupChild (child : IO.Process.Child childStdio) : IO Unit := do
  try
    child.kill
  catch _ =>
    pure ()
  IO.sleep 100
  try
    discard <| child.tryWait
  catch _ =>
    pure ()

def run (kind : String) : IO Unit := do
  debugLog s!"standalone repro start kind={kind}"
  let root ← makeWorkspace
  debugLog s!"temporary Lake workspace root={root}"
  let child ← prepareChild kind root
  try
    let ws ← loadWorkspace root
    debugLog s!"checkNoBuild trivial start kind={kind}"
    let trivial : FetchM (Job Unit) := pure (Job.nil "stderr-lake-repro")
    let ready ← ws.checkNoBuild trivial
    debugLog s!"checkNoBuild trivial done kind={kind} ready={ready}"
  finally
    cleanupChild child
  debugLog s!"standalone repro done kind={kind}"

def runCheckNoBuildInTask (kind : String) : IO Unit := do
  debugLog s!"task repro start kind={kind}"
  let root ← makeWorkspace
  debugLog s!"temporary Lake workspace root={root}"
  let child ← prepareChild kind root
  try
    let task ← IO.asTask do
      let ws ← loadWorkspace root
      debugLog s!"checkNoBuild task trivial start kind={kind}"
      let trivial : FetchM (Job Unit) := pure (Job.nil "stderr-lake-repro-task")
      let ready ← ws.checkNoBuild trivial
      debugLog s!"checkNoBuild task trivial done kind={kind} ready={ready}"
    match ← IO.wait task with
    | .ok () =>
        debugLog s!"task repro check task done kind={kind}"
    | .error e =>
        throw e
  finally
    cleanupChild child
  debugLog s!"task repro done kind={kind}"

private def expectOkResponse (label : String) (resp : Beam.Broker.Response) : IO Json := do
  if resp.ok then
    match resp.result? with
    | some result => pure result
    | none => throw <| IO.userError s!"{label} response was ok but had no result"
  else
    throw <| IO.userError s!"{label} failed: {(toJson resp).compress}"

private def dispatchOk
    (server : Beam.Broker.ServerRuntime)
    (label : String)
    (req : Beam.Broker.Request) : IO Json := do
  let (resp, _shouldStop) ← server.dispatchRequest req
  expectOkResponse label resp

def runDirectBrokerSave : IO Unit := do
  debugLog "direct broker save start"
  let root ← IO.FS.realPath (FilePath.mk ".")
  let plugin ← pluginPath
  let server ← Beam.Broker.ServerRuntime.create {
    root
    leanCmd? := some "lean"
    leanPlugin? := some plugin
    rocqCmd? := none
  }
  try
    let _ ← dispatchOk server "ensure" {
      op := .ensure
      backend := .lean
      root? := some root.toString
    }
    let _ ← dispatchOk server "reset_stats" {
      op := .resetStats
      root? := some root.toString
    }
    let savePayload ← dispatchOk server "save_olean" {
      op := .saveOlean
      backend := .lean
      root? := some root.toString
      path? := some "RunAtTest/Deps/DepA.lean"
    }
    debugLog s!"direct broker save payload={savePayload.compress}"
  finally
    try
      let _ ← dispatchOk server "shutdown" {
        op := .shutdown
        root? := some root.toString
      }
    catch e =>
      debugLog s!"direct broker shutdown failed: {e.toString}"
  debugLog "direct broker save done"

def runDirectBrokerSaveTask : IO Unit := do
  debugLog "direct broker save task wrapper start"
  let task ← IO.asTask runDirectBrokerSave
  match ← IO.wait task with
  | .ok () =>
      debugLog "direct broker save task wrapper done"
  | .error e =>
      throw e

end RunAtTest.Broker.StderrLakeRepro

def main (args : List String) : IO UInt32 := do
  let kind := args.head?.getD "lean-server"
  try
    if kind == "sleep-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "sleep"
    else if kind == "sleep-dual-dedicated-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "sleep-dual-dedicated"
    else if kind == "sleep-dual-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "sleep-dual"
    else if kind == "lean-server-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-server"
    else if kind == "lean-server-dual-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-server-dual"
    else if kind == "lean-session-no-readers-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-session-no-readers"
    else if kind == "lean-session-no-stderr-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-session-no-stderr"
    else if kind == "lean-session-no-stdout-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-session-no-stdout"
    else if kind == "lean-session-dedicated-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-session-dedicated"
    else if kind == "lean-session-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-session"
    else if kind == "lean-open-no-stderr-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-open-no-stderr"
    else if kind == "lean-open-no-stdout-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-open-no-stdout"
    else if kind == "lean-open-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-open"
    else if kind == "lean-plugin-open-task" then
      RunAtTest.Broker.StderrLakeRepro.runCheckNoBuildInTask "lean-plugin-open"
    else if kind == "broker-direct-task" then
      RunAtTest.Broker.StderrLakeRepro.runDirectBrokerSaveTask
    else if kind == "broker-direct" then
      RunAtTest.Broker.StderrLakeRepro.runDirectBrokerSave
    else
      RunAtTest.Broker.StderrLakeRepro.run kind
    pure 0
  catch e =>
    IO.eprintln s!"beam-debug: standalone repro failed: {e.toString}"
    pure 1
