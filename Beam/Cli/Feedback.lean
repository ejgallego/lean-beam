/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Cli.Args
import Beam.Cli.DaemonManager
import Beam.Cli.Lock
import Beam.Cli.Output
import Beam.Cli.Project
import Beam.Daemon.Debug
import Beam.Feedback
import Beam.Feedback.Broker
import Beam.Version

open Lean

namespace Beam.Cli.Feedback

open Beam.Broker

structure Options where
  input? : Option String := none
  bundle? : Option Beam.Feedback.BundleMode := none
  outputDir? : Option System.FilePath := none
  redact? : Option Bool := none

def usage : String :=
  "usage: beam [--root PATH] feedback --stdin|--input <path> [--bundle none|dir|zip] [--output-dir <path>] [--no-redact]"

def inputShapeHelp : String :=
  s!"input must be a JSON object with required string fields: {Beam.Feedback.requiredInputFieldsText}"

def help : String :=
  String.intercalate "\n" [
    usage,
    "",
    inputShapeHelp,
    "optional fields: impact, workaround, tags, client_request_id, request, response, evidence, bundle, redact",
    "example:",
    "  {\"title\":\"Daemon startup failure\",\"summary\":\"Beam failed to start\",\"reproduction\":\"lean-beam run-at Demo.lean 1 0\",\"expected\":\"A response is returned.\",\"actual\":\"The daemon closed the connection.\"}"
  ]

private def parseBundleMode (raw : String) : IO Beam.Feedback.BundleMode := do
  match fromJson? (α := Beam.Feedback.BundleMode) (Json.str raw) with
  | .ok mode => pure mode
  | .error err => throw <| IO.userError s!"invalid feedback bundle mode: {err}"

partial def parseOptions (opts : Options) : List String → IO Options
  | [] => pure opts
  | "--stdin" :: rest => do
      let text ← (← IO.getStdin).readToEnd
      parseOptions { opts with input? := some text } rest
  | "--input" :: path :: rest => do
      let text ← IO.FS.readFile (System.FilePath.mk path)
      parseOptions { opts with input? := some text } rest
  | "--input" :: _ => throw <| IO.userError usage
  | "--bundle" :: mode :: rest => do
      parseOptions { opts with bundle? := some (← parseBundleMode mode) } rest
  | "--bundle" :: _ => throw <| IO.userError usage
  | "--output-dir" :: path :: rest => do
      parseOptions { opts with outputDir? := some (System.FilePath.mk path) } rest
  | "--output-dir" :: _ => throw <| IO.userError usage
  | "--no-redact" :: rest =>
      parseOptions { opts with redact? := some false } rest
  | _ => throw <| IO.userError usage

private def versionIdentityJson (home : System.FilePath) : IO Json := do
  let appPath ← IO.appPath
  let wrapper? ← IO.getEnv "BEAM_WRAPPER_PATH"
  let publicCommand? ← IO.getEnv "BEAM_PUBLIC_COMMAND"
  let identity ← Beam.Version.mkRuntimeIdentity
    (publicCommand?.getD "beam-cli")
    (some home)
    (wrapper? := wrapper?)
    (beamCli? := some appPath.toString)
  pure identity.asJson

private def collectDaemonPayload
    (root : System.FilePath)
    (warnings : Array String) : IO (Json × Json × Array String) := do
  match ← registryLiveFor root with
  | none =>
      pure (Json.null, Json.null, warnings.push "no live Beam daemon was available for stats/open-files")
  | some entry =>
      match Beam.Daemon.registryEndpoint? entry with
      | none =>
          pure (Json.null, Json.null, warnings.push "Beam daemon registry did not contain a valid endpoint")
      | some endpoint =>
          let statsResp ← sendRequest endpoint { op := .stats }
          let (stats, warnings) := Beam.Feedback.responsePayloadOrWarning "stats" statsResp warnings
          let openResp ← sendRequest endpoint { op := .openDocs, root? := some root.toString }
          let (openDocs, warnings) := Beam.Feedback.responsePayloadOrWarning "open-files" openResp warnings
          pure (stats, openDocs, warnings)

private def collect
    (home : System.FilePath)
    (root? : Option System.FilePath)
    (warnings : Array String) : IO Beam.Feedback.Collection := do
  let generatedAt ← utcTimestamp
  let identity ← versionIdentityJson home
  let (stats, openDocs, daemon, warnings) ←
    match root? with
    | none =>
        pure (Json.null, Json.null, Json.null,
          warnings.push "could not infer project root; daemon debug context was not collected")
    | some root => do
        let daemon ← daemonDebugContextJson root
        let warnings := warnings ++ Beam.Daemon.daemonDebugWarnings daemon
        let (stats, openDocs, warnings) ← collectDaemonPayload root warnings
        pure (stats, openDocs, daemon, warnings)
  pure {
    generatedAt
    activeRoot? := root?.map (·.toString)
    data := Json.mkObj [
      ("identity", identity),
      ("stats", stats),
      ("openFiles", openDocs),
      ("daemon", daemon)
    ]
    warnings
  }

def run (home : System.FilePath) (cliOpts : CliOptions) (args : List String) : IO Unit := do
  if args == ["--help"] || args == ["-h"] then
    IO.println help
    return
  let opts ← parseOptions {} args
  let inputText ←
    match opts.input? with
    | some text => pure text
    | none => throw <| IO.userError help
  let json ←
    try
      parseJsonText "feedback input json" inputText
    catch e =>
      throw <| IO.userError s!"invalid feedback input: {inputShapeHelp}; {e.toString}"
  let input ←
    match fromJson? (α := Beam.Feedback.Input) json with
    | .ok input => pure input
    | .error err => throw <| IO.userError s!"invalid feedback input: {err}"
  let input := (input.withBundle opts.bundle?).withRedactOverride opts.redact?
  let (root?, warnings) ←
    try
      let root ← projectRootAny cliOpts
      pure (some root, #[])
    catch e =>
      pure (none, #[e.toString])
  let collection ← collect home root? warnings
  let allowedRoots ←
    match root? with
    | some root => do
        let control ← controlDir root
        pure #[root, control]
    | none => pure #[]
  let result ← Beam.Feedback.buildResult input collection {
    root?
    outputDir? := opts.outputDir?
    allowedRoots
  }
  printJsonLine <| Beam.Feedback.Result.toJson result

end Beam.Cli.Feedback
