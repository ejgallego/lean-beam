/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Args
import Beam.Cli.Broker
import Beam.Cli.DaemonManager
import Beam.Cli.Info
import Beam.Cli.LeanOperation
import Beam.Cli.Lock
import Beam.Cli.Project
import Beam.Cli.RuntimeBundle
import Beam.Cli.Usage
import Std.Internal.UV.Signal

open Lean

namespace Beam.Cli

open Beam.Broker

private def runLeanRunAt
    (home : System.FilePath)
    (opts : CliOptions)
    (action path lineText characterText : String)
    (textArgs : List String)
    (storeHandle : Bool := false) : IO Unit := do
  let root ← projectRoot opts .lean
  let daemon ← ensureProjectDaemon home root .lean opts
  let line ← parseNatArg "line" lineText
  let character ← parseNatArg "character" characterText
  let parsedText ← parseTextArg s!"{action} <path> <line> <character>" textArgs
  let req ← withEnvClientRequestId <|
    leanRunAtRequest root path line character parsedText.text? (storeHandle := storeHandle)
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text?
  withWrapperLease root daemon.startedNew do
    callBrokerWithProgress root daemon.endpoint req (leanRunAtWaitSpec action path line character)

private def runLeanRunWith
    (home : System.FilePath)
    (opts : CliOptions)
    (action path : String)
    (args : List String)
    (linear : Bool := false) : IO Unit := do
  let textArgs :=
    match args with
    | [] => []
    | "--handle-file" :: _ :: rest => rest
    | _ :: rest => rest
  if handleArgReadsStdin args && textArgReadsStdin textArgs then
    throw <| IO.userError <| String.intercalate "\n" [
      textArgUsage s!"{action} <path> <handle-json|-|--handle-file <path>>",
      "cannot read both handle json and continuation text from stdin; pass the handle inline, use --handle-file, or use --text-file for the text"
    ]
  let root ← projectRoot opts .lean
  let daemon ← ensureProjectDaemon home root .lean opts
  let (handle, textArgs) ← parseHandleInput s!"{action} <path>" args
  let parsedText ← parseTextArg s!"{action} <path> <handle-json|-|--handle-file <path>>" textArgs
  let req ← withEnvClientRequestId <|
    leanRunWithRequest root path handle parsedText.text? (linear := linear)
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text?
  withWrapperLease root daemon.startedNew do
    callBrokerWithProgress root daemon.endpoint req (leanRunWithWaitSpec path (linear := linear))

private def runLeanRelease
    (home : System.FilePath)
    (opts : CliOptions)
    (path : String)
    (args : List String) : IO Unit := do
  let root ← projectRoot opts .lean
  let daemon ← ensureProjectDaemon home root .lean opts
  let (handle, extra) ← parseHandleInput "lean-release <path>" args
  unless extra.isEmpty do
    throw <| IO.userError (handleArgUsage "lean-release <path>")
  withWrapperLease root daemon.startedNew do
    callBroker root daemon.endpoint <| leanReleaseRequest root path handle

private def shutdownProjectDaemon (opts : CliOptions) : IO Unit := do
  let root ← projectRootAny opts
  withProjectControlLock root do
    match ← registryLiveFor root with
    | some entry =>
        if let some endpoint := registryEndpoint? entry then
          let resp ← sendRequest endpoint { op := .shutdown }
          printResponse resp
          waitForPidGone entry.pid
          if ← pidAlive entry.pid then
            killPid entry.pid
            waitForPidGone entry.pid
          removeRegistry root
        else
          stopRegisteredDaemon root
          printJsonLine <| Json.mkObj [
            ("result", Json.mkObj [("shutdown", toJson false), ("reason", toJson ("notFound" : String))])
          ]
    | none =>
        stopRegisteredDaemon root
        printJsonLine <| Json.mkObj [
          ("result", Json.mkObj [("shutdown", toJson false), ("reason", toJson ("notFound" : String))])
        ]

private def backendOfName (name : String) : Backend :=
  if name == "rocq" then .rocq else .lean

private def holdUntilInterrupted : IO Unit := do
  let signal ← Std.Internal.UV.Signal.mk 2 false
  try
    let promise ← Std.Internal.UV.Signal.next signal
    let some _ ← IO.wait promise.result?
      | throw <| IO.userError "SIGINT watcher promise dropped"
    pure ()
  finally
    Std.Internal.UV.Signal.stop signal

private def ensureBackend
    (home : System.FilePath)
    (opts : CliOptions)
    (backend : Backend)
    (hold : Bool := false) : IO Unit := do
  let root ← projectRoot opts backend
  let daemon ← ensureProjectDaemon home root backend opts
  withWrapperLease root daemon.startedNew do
    callBroker root daemon.endpoint { op := .ensure, backend := backend, root? := some root.toString }
    if hold then
      (← IO.getStdout).flush
      IO.eprintln "beam: holding ensured daemon; interrupt this wrapper process when finished"
      holdUntilInterrupted

def runCommand (home : System.FilePath) (opts : CliOptions) : IO Unit := do
  match opts.args with
  | [] =>
      throw <| IO.userError usage
  | "experimental" :: [] =>
      printExperimentalInfo home
  | "bundle-install" :: toolchain :: [] =>
      let cacheRoot ←
        match ← IO.getEnv "BEAM_INSTALL_BUNDLE_DIR" with
        | some path => pure <| System.FilePath.mk path
        | none =>
            let roots ← installBundleCacheRoots
            pure <| roots.headD (runAtStateDir home / installBundlesDirName)
      let _ ← ensureToolchainBundleIn cacheRoot home toolchain
      pure ()
  | "supported-toolchains" :: backend :: [] =>
      printSupportedToolchains home backend
  | "install-layout" :: [] =>
      printInstallLayout
  | "install-manifest" :: payloadHash :: sourceCommitArg :: toolchains =>
      printInstallManifest payloadHash sourceCommitArg toolchains
  | "mcp-config" :: [] =>
      printMcpConfig home opts
  | "ensure" :: [] =>
      ensureBackend home opts .lean
  | "ensure" :: "--hold" :: [] =>
      ensureBackend home opts .lean (hold := true)
  | "ensure" :: backend :: [] =>
      ensureBackend home opts (backendOfName backend)
  | "ensure" :: backend :: "--hold" :: [] =>
      ensureBackend home opts (backendOfName backend) (hold := true)
  | "lean-run-at" :: path :: line :: character :: text =>
      runLeanRunAt home opts "lean-run-at" path line character text
  | "lean-run-at-handle" :: path :: line :: character :: text =>
      runLeanRunAt home opts "lean-run-at-handle" path line character text (storeHandle := true)
  | "lean-hover" :: path :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanHoverRequest root path line character)
          (leanHoverWaitSpec path line character)
  | "lean-goals-after" :: path :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanGoalsAfterRequest root path line character)
          (leanGoalsWaitSpec path line character .after)
  | "lean-goals-prev" :: path :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanGoalsPrevRequest root path line character)
          (leanGoalsWaitSpec path line character .prev)
  | "lean-todo" :: path :: startLine :: startCharacter :: endLine :: endCharacter :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let startLine ← parseNatArg "startLine" startLine
      let startCharacter ← parseNatArg "startCharacter" startCharacter
      let endLine ← parseNatArg "endLine" endLine
      let endCharacter ← parseNatArg "endCharacter" endCharacter
      let (kinds?, suggest?) ← parseLeanTodoArgs extra
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanTodoRequest root path startLine startCharacter endLine endCharacter kinds? suggest?)
          (leanTodoWaitSpec path startLine startCharacter endLine endCharacter)
  | "lean-request-at" :: path :: line :: character :: method :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let params? ←
        match extra with
        | [] => pure none
        | [raw] => pure <| some (← parseJsonArg "request params json" raw)
        | _ => throw <| IO.userError usage
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint {
          op := .requestAt
          backend := .lean
          root? := some root.toString
          path? := some path
          line? := some line
          character? := some character
          method? := some method
          params? := params?
        } (leanRequestAtWaitSpec path line character method)
  | "lean-run-with" :: path :: args =>
      runLeanRunWith home opts "lean-run-with" path args
  | "lean-run-with-linear" :: path :: args =>
      runLeanRunWith home opts "lean-run-with-linear" path args (linear := true)
  | "lean-release" :: path :: args =>
      runLeanRelease home opts path args
  | "lean-deps" :: path :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      withWrapperLease root daemon.startedNew do
        callBroker root daemon.endpoint <| leanDepsRequest root path
  | "lean-save" :: path :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanSaveArgs extra
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanSaveRequest root path fullDiagnostics)
          (leanSaveWaitSpec path)
  | "lean-sync" :: path :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanSyncArgs extra
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanSyncRequest root path fullDiagnostics)
          (syncWaitSpec path)
  | "lean-refresh" :: path :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanRefreshArgs extra
      withWrapperLease root daemon.startedNew do
        callBrokerQuiet root daemon.endpoint <| leanCloseRequest root path
        callBrokerWithProgress root daemon.endpoint
          (leanSyncRequest root path fullDiagnostics)
          (refreshWaitSpec path)
  | "lean-close" :: path :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      withWrapperLease root daemon.startedNew do
        callBroker root daemon.endpoint <| leanCloseRequest root path
  | "lean-close-save" :: path :: extra =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanCloseSaveArgs extra
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanCloseSaveRequest root path fullDiagnostics)
          (leanSaveWaitSpec path (closeAfter := true))
  | "rocq-goals-after" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      let daemon ← ensureProjectDaemon home root .rocq opts
      withWrapperLease root daemon.startedNew do
        callBroker root daemon.endpoint {
          op := .goals
          backend := .rocq
          root? := some root.toString
          path? := some path
          line? := some (← parseNatArg "line" line)
          character? := some (← parseNatArg "character" character)
          mode? := some .after
          compact? := some false
          ppFormat? := some .str
          text? := joinTextArgs text
        }
  | "rocq-goals-prev" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      let daemon ← ensureProjectDaemon home root .rocq opts
      withWrapperLease root daemon.startedNew do
        callBroker root daemon.endpoint {
          op := .goals
          backend := .rocq
          root? := some root.toString
          path? := some path
          line? := some (← parseNatArg "line" line)
          character? := some (← parseNatArg "character" character)
          mode? := some .prev
          compact? := some false
          ppFormat? := some .str
          text? := joinTextArgs text
        }
  | "doctor" :: backend :: [] =>
      doctor home opts (if backend == "rocq" then .rocq else .lean)
  | "open-files" :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint { op := .openDocs, root? := some root.toString }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "cancel" :: requestId :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint {
          op := .cancel
          root? := some root.toString
          cancelRequestId? := some requestId
        }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "stats" :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint { op := .stats }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "reset-stats" :: [] =>
      let root ← projectRootAny opts
      let entry ← lookupProjectDaemon root
      if let some endpoint := registryEndpoint? entry then
        callBroker root endpoint { op := .resetStats }
      else
        throw <| IO.userError s!"invalid Beam daemon endpoint registry for {entry.root}"
  | "shutdown" :: [] =>
      shutdownProjectDaemon opts
  | _ =>
      throw <| IO.userError usage

end Beam.Cli
