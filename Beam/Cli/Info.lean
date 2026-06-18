/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.DaemonManager
import Beam.Cli.InstallLayout
import Beam.Cli.Output
import Beam.Cli.Project
import Beam.Cli.RuntimeBundle

open Lean

namespace Beam.Cli

open Beam.Broker

private def printLeanDoctorInfo (home root : System.FilePath) : IO Unit := do
  let toolchain ← leanToolchain root
  let support ← leanToolchainSupport home toolchain
  let toolchainSupported := support.acceptance == .supported
  let toolchainCustom := support.acceptance == .custom
  let toolchainAccepted := support.acceptance.accepted
  let leanCmd? ←
    if toolchainAccepted then
      let leanCmd ← leanBin root
      pure (some leanCmd)
    else
      pure none
  let runtimeRoot ← runtimeBundleCacheRoot root
  let platform ← bundlePlatform
  let srcHash ← sourceHash home
  let installed? ← existingToolchainBundleInAny? (← installBundleCacheRoots) home toolchain
  let runtime? ← existingToolchainBundle? runtimeRoot home toolchain
  let (paths, bundleId, source, ready) ←
    match installed? with
    | some (paths, bundleId) => pure (paths, bundleId, "installed", true)
    | none =>
        match runtime? with
        | some (paths, bundleId) => pure (paths, bundleId, "runtime", true)
        | none =>
            let (paths, bundleId) ← predictedToolchainBundle runtimeRoot home toolchain
            pure (paths, bundleId, "missing", false)
  IO.println s!"project toolchain: {toolchain}"
  IO.println s!"project toolchain supported: {boolText toolchainSupported}"
  IO.println s!"project toolchain custom: {boolText toolchainCustom}"
  IO.println s!"project toolchain accepted: {boolText toolchainAccepted}"
  IO.println s!"supported toolchains registry: {support.supportedPath}"
  IO.println s!"custom toolchains registry: {support.customPath}"
  IO.println s!"lean binary: {leanCmd?.getD "(not resolved for rejected toolchain)"}"
  IO.println s!"bundle platform: {platform}"
  IO.println s!"bundle source: {source}"
  IO.println s!"bundle source hash: {srcHash}"
  IO.println "bundle key inputs: toolchain, platform, source hash"
  IO.println s!"bundle source inputs: {String.intercalate ", " bundleSourceHashInputLabels}"
  IO.println s!"bundle id: {bundleId}"
  IO.println s!"bundle ready: {boolText ready}"
  IO.println s!"bundle daemon: {paths.daemon}"
  IO.println s!"bundle client: {paths.client}"
  IO.println s!"plugin: {paths.plugin}"

private def printRocqDoctorInfo (home root : System.FilePath) : IO Unit := do
  let paths ← defaultBundlePaths home
  let helpersReady := (← paths.daemon.pathExists) && (← paths.client.pathExists)
  IO.println s!"coq-lsp: {(← maybeRocqCmd root).getD ""}"
  IO.println s!"daemon helpers ready: {boolText helpersReady}"
  IO.println s!"daemon binary: {paths.daemon}"
  IO.println s!"client binary: {paths.client}"

def doctor (home : System.FilePath) (opts : CliOptions) (backend : Backend) : IO Unit := do
  let root ← projectRoot opts backend
  IO.println s!"beam home: {home}"
  IO.println s!"project root: {root}"
  match backend with
  | .lean => printLeanDoctorInfo home root
  | .rocq => printRocqDoctorInfo home root
  let registry ← registryPath root
  IO.println s!"registry: {registry}"
  match ← registryLiveFor root with
  | some entry =>
      IO.println "daemon status: live"
      IO.println s!"daemon pid: {entry.pid}"
      if let some pidNamespace := entry.pidNamespace? then
        IO.println s!"daemon pid namespace: {pidNamespace}"
      if let some endpoint := registryEndpoint? entry then
        IO.println s!"daemon endpoint: {endpointSummary endpoint}"
      else
        IO.println "daemon endpoint: invalid"
      IO.println s!"daemon config hash: {entry.configHash}"
  | none =>
      if ← registry.pathExists then
        IO.println "daemon status: stale"
      else
        IO.println "daemon status: absent"

def printSupportedToolchains (home : System.FilePath) (backendName : String) : IO Unit := do
  match backendName with
  | "lean" =>
      let (_, toolchains) ← supportedLeanToolchains home
      for toolchain in toolchains do
        IO.println toolchain
  | _ =>
      throw <| IO.userError "usage: lean-beam supported-toolchains"

def printInstallLayout : IO Unit := do
  printJsonLine (toJson installLayout)

def printInstallManifest (payloadHash : String) (sourceCommitArg : String) (toolchains : List String) : IO Unit := do
  if toolchains.isEmpty then
    throw <| IO.userError "usage: beam install-manifest <payload-hash> <source-commit|-> <toolchain...>"
  let sourceCommit? :=
    if sourceCommitArg == "-" then
      none
    else
      some sourceCommitArg
  printJsonLine (installManifestJson payloadHash sourceCommit? toolchains)

def printMcpConfig (home : System.FilePath) (opts : CliOptions) : IO Unit := do
  let root ← projectRoot opts .lean
  let desired ← desiredConfig home root .lean
  let some leanCmd := desired.leanCmd?
    | throw <| IO.userError s!"could not resolve Lean command for MCP project root {root}"
  let some plugin := desired.plugin?
    | throw <| IO.userError s!"could not resolve runAt plugin for MCP project root {root}"
  printJsonLine <| Json.mkObj [
    ("root", toJson root.toString),
    ("lean_cmd", toJson leanCmd),
    ("lean_plugin", toJson plugin.toString),
    ("toolchain", toJson desired.toolchain?),
    ("bundle_id", toJson desired.bundleId)
  ]

end Beam.Cli
