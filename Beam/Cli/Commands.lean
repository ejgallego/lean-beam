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

private def wrapperDisplayAction (fallback : String) : IO String := do
  match ← IO.getEnv "BEAM_WRAPPER_COMMAND" with
  | some action => pure action
  | none => pure fallback

private def syncVersionForRocqGoals
    (root : System.FilePath)
    (endpoint : Transport.Endpoint)
    (path : String) : IO Nat := do
  let resp ← sendRequest endpoint {
    op := .syncFile
    backend := .rocq
    root? := some root.toString
    path? := some path
    fullDiagnostics? := some false
  }
  failOnError resp
  let some result := decodeSyncFileResult? resp
    | throw <| IO.userError "sync_file returned an invalid response while obtaining document version"
  pure result.version

private def runLeanRunAt
    (home : System.FilePath)
    (opts : CliOptions)
    (action path versionText lineText characterText : String)
    (textArgs : List String)
    (storeHandle : Bool := false) : IO Unit := do
  let root ← projectRoot opts .lean
  let daemon ← ensureProjectDaemon home root .lean opts
  let version ← parseNatArg "version" versionText
  let line ← parseNatArg "line" lineText
  let character ← parseNatArg "character" characterText
  let parsedText ← parseTextArg s!"{action} <path> <version> <line> <character>" textArgs
  withWrapperLease root daemon.startedNew do
    let req ← withEnvClientRequestId <|
      leanRunAtRequest root path version line character parsedText.text? (storeHandle := storeHandle)
    maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text?
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
    (action : String)
    (path : String)
    (args : List String) : IO Unit := do
  let root ← projectRoot opts .lean
  let daemon ← ensureProjectDaemon home root .lean opts
  let (handle, extra) ← parseHandleInput s!"{action} <path>" args
  unless extra.isEmpty do
    throw <| IO.userError (handleArgUsage s!"{action} <path>")
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
  | "lean-run-at" :: path :: version :: line :: character :: text =>
      runLeanRunAt home opts (← wrapperDisplayAction "lean-run-at") path version line character text
  | "lean-run-at-handle" :: path :: version :: line :: character :: text =>
      runLeanRunAt home opts (← wrapperDisplayAction "lean-run-at-handle") path version line character text
        (storeHandle := true)
  | "lean-hover" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-hover"
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanHoverRequest root path version line character)
          (leanHoverWaitSpec path line character action)
  | "lean-goals-after" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-goals-after"
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanGoalsAfterRequest root path version line character)
          (leanGoalsWaitSpec path line character .after (some action))
  | "lean-goals-prev" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-goals-prev"
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanGoalsPrevRequest root path version line character)
          (leanGoalsWaitSpec path line character .prev (some action))
  | "lean-todo" :: path :: versionText :: startLine :: startCharacter :: endLine :: endCharacter :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let version ← parseNatArg "version" versionText
      let startLine ← parseNatArg "startLine" startLine
      let startCharacter ← parseNatArg "startCharacter" startCharacter
      let endLine ← parseNatArg "endLine" endLine
      let endCharacter ← parseNatArg "endCharacter" endCharacter
      let (kinds?, suggest?) ← parseLeanTodoArgs extra
      let action ← wrapperDisplayAction "lean-todo"
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanTodoRequest root path version startLine startCharacter endLine endCharacter kinds? suggest?)
          (leanTodoWaitSpec path startLine startCharacter endLine endCharacter action)
  | "lean-request-at" :: path :: versionText :: line :: character :: method :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action ← wrapperDisplayAction "lean-request-at"
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
          version? := some version
          line? := some line
          character? := some character
          method? := some method
          params? := params?
        } (leanRequestAtWaitSpec path line character method action)
  | "lean-run-with" :: path :: args =>
      runLeanRunWith home opts (← wrapperDisplayAction "lean-run-with") path args
  | "lean-run-with-linear" :: path :: args =>
      runLeanRunWith home opts (← wrapperDisplayAction "lean-run-with-linear") path args
        (linear := true)
  | "lean-release" :: path :: args =>
      runLeanRelease home opts (← wrapperDisplayAction "lean-release") path args
  | "deps" :: path :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      withWrapperLease root daemon.startedNew do
        callBroker root daemon.endpoint <| leanDepsRequest root path
  | "lean-save" :: path :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanSaveArgs extra
      let action ← wrapperDisplayAction "lean-save"
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanSaveRequest root path fullDiagnostics)
          (leanSaveWaitSpec path (action? := some action))
  | "lean-sync" :: path :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanSyncArgs extra
      let action ← wrapperDisplayAction "lean-sync"
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanSyncRequest root path fullDiagnostics)
          (syncWaitSpec path action)
  | "lean-refresh" :: path :: extra => do
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanRefreshArgs extra
      let action ← wrapperDisplayAction "lean-refresh"
      withWrapperLease root daemon.startedNew do
        callBrokerQuiet root daemon.endpoint <| leanCloseRequest root path
        callBrokerWithProgress root daemon.endpoint
          (leanSyncRequest root path fullDiagnostics)
          (refreshWaitSpec path action)
  | "lean-close" :: path :: [] =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      withWrapperLease root daemon.startedNew do
        callBroker root daemon.endpoint <| leanCloseRequest root path
  | "lean-close-save" :: path :: extra =>
      let root ← projectRoot opts .lean
      let daemon ← ensureProjectDaemon home root .lean opts
      let fullDiagnostics ← parseLeanCloseSaveArgs extra
      let action ← wrapperDisplayAction "lean-close-save"
      withWrapperLease root daemon.startedNew do
        callBrokerWithProgress root daemon.endpoint
          (leanCloseSaveRequest root path fullDiagnostics)
          (leanSaveWaitSpec path (closeAfter := true) (action? := some action))
  | "rocq-goals-after" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      let daemon ← ensureProjectDaemon home root .rocq opts
      withWrapperLease root daemon.startedNew do
        let version ← syncVersionForRocqGoals root daemon.endpoint path
        callBroker root daemon.endpoint {
          op := .goals
          backend := .rocq
          root? := some root.toString
          path? := some path
          version? := some version
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
        let version ← syncVersionForRocqGoals root daemon.endpoint path
        callBroker root daemon.endpoint {
          op := .goals
          backend := .rocq
          root? := some root.toString
          path? := some path
          version? := some version
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
