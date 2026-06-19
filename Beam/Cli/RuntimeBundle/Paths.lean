/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Lock
import RunAt.Lib.NativeLib

open Lean

namespace Beam.Cli

structure BundlePaths where
  daemon : System.FilePath
  client : System.FilePath
  plugin : System.FilePath
  deriving Repr

def defaultBundlePaths (home : System.FilePath) : IO BundlePaths := do
  let installedDaemon := home / "libexec" / "beam-daemon"
  let installedClient := home / "libexec" / "beam-client"
  let installedPlugin := RunAt.Lib.pluginSharedLibPath (home / "libexec")
  let checkoutDaemon := home / ".lake" / "build" / "bin" / "beam-daemon"
  let checkoutClient := home / ".lake" / "build" / "bin" / "beam-client"
  let checkoutPlugin := RunAt.Lib.pluginSharedLibPath (home / ".lake" / "build" / "lib")
  let installedReady :=
    (← installedDaemon.pathExists) &&
    (← installedClient.pathExists) &&
    (← installedPlugin.pathExists)
  pure <|
    if installedReady then
      {
        daemon := installedDaemon
        client := installedClient
        plugin := installedPlugin
      }
    else
      {
        daemon := checkoutDaemon
        client := checkoutClient
        plugin := checkoutPlugin
      }

def ensurePathExists (kind : String) (path : System.FilePath) : IO Unit := do
  unless ← path.pathExists do
    throw <| IO.userError s!"missing {kind} at {path}"

def ensureBundleExists (paths : BundlePaths) : IO Unit := do
  ensurePathExists "CLI client" paths.client
  ensurePathExists "Beam daemon" paths.daemon

def ensureLeanBundleExists (paths : BundlePaths) : IO Unit := do
  ensureBundleExists paths
  ensurePathExists "runAt plugin" paths.plugin

def runAtStateDirName : String :=
  ".beam"

def installBundlesDirName : String :=
  "install-bundles"

def runtimeBundlesDirName : String :=
  "bundles"

def runAtStateDir (root : System.FilePath) : System.FilePath :=
  root / runAtStateDirName

def skillInstallBundleCacheRoot (agentHome : System.FilePath) : System.FilePath :=
  agentHome / "skills" / "lean-beam" / runAtStateDirName / installBundlesDirName

def defaultEnvPath (name : String) (fallback : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv name with
  | some path => pure <| System.FilePath.mk path
  | none => pure fallback

def userHome : IO System.FilePath := do
  match ← IO.getEnv "HOME" with
  | some path => pure <| System.FilePath.mk path
  | none => throw <| IO.userError "missing HOME in environment"

def installBundleCacheRoots : IO (List System.FilePath) := do
  match ← IO.getEnv "BEAM_INSTALL_BUNDLE_DIR" with
  | some path => pure [System.FilePath.mk path]
  | none =>
      let home ← userHome
      let codexHome ← defaultEnvPath "CODEX_HOME" (home / ".codex")
      let claudeHome ← defaultEnvPath "CLAUDE_HOME" (home / ".claude")
      pure [
        skillInstallBundleCacheRoot codexHome,
        skillInstallBundleCacheRoot claudeHome
      ]

def runtimeBundleCacheRoot (root : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv "BEAM_BUNDLE_DIR" with
  | some path => pure (System.FilePath.mk path)
  | none => pure (runAtStateDir root / runtimeBundlesDirName)

def supportedLeanToolchainsPath (home : System.FilePath) : System.FilePath :=
  home / "supported-lean-toolchains"

def customLeanToolchainsPath (home : System.FilePath) : System.FilePath :=
  home / "custom-lean-toolchains"

def nonCommentLines (text : String) : List String :=
  (text.splitOn "\n").filterMap fun raw =>
    let line := trimLine raw
    if line.isEmpty || line.startsWith "#" then none else some line

def supportedLeanToolchains (home : System.FilePath) : IO (System.FilePath × List String) := do
  let path := supportedLeanToolchainsPath home
  unless ← path.pathExists do
    throw <| IO.userError s!"missing supported Lean toolchain registry at {path}"
  pure (path, nonCommentLines (← IO.FS.readFile path))

def customLeanToolchains (home : System.FilePath) : IO (System.FilePath × List String) := do
  let path := customLeanToolchainsPath home
  unless ← path.pathExists do
    return (path, [])
  pure (path, nonCommentLines (← IO.FS.readFile path))

inductive LeanToolchainAcceptance where
  | supported
  | custom
  | unsupported
  deriving BEq, Repr

def LeanToolchainAcceptance.accepted : LeanToolchainAcceptance → Bool
  | .supported => true
  | .custom => true
  | .unsupported => false

structure LeanToolchainSupport where
  supportedPath : System.FilePath
  supportedToolchains : List String
  customPath : System.FilePath
  customToolchains : List String
  acceptance : LeanToolchainAcceptance
  deriving Repr

def leanToolchainSupport (home : System.FilePath) (toolchain : String) : IO LeanToolchainSupport := do
  let (supportedPath, supportedToolchains) ← supportedLeanToolchains home
  let (customPath, customToolchains) ← customLeanToolchains home
  let acceptance :=
    if supportedToolchains.elem toolchain then
      .supported
    else if customToolchains.elem toolchain then
      .custom
    else
      .unsupported
  pure {
    supportedPath
    supportedToolchains
    customPath
    customToolchains
    acceptance
  }

def ensureAcceptedLeanToolchain (home : System.FilePath) (toolchain : String) : IO Unit := do
  let support ← leanToolchainSupport home toolchain
  unless support.acceptance.accepted do
    throw <| IO.userError <| String.intercalate "\n" [
      s!"unsupported Lean toolchain: {toolchain}",
      s!"supported toolchain registry: {support.supportedPath}",
      s!"custom toolchain registry: {support.customPath}",
      "run `lean-beam supported-toolchains` to list the validated toolchains",
      "for local Lean development toolchains, reinstall Beam with `./scripts/install-beam.sh --custom-toolchain TOOLCHAIN`"
    ]

def boolText (value : Bool) : String :=
  if value then "true" else "false"

private def hexDigit (n : Nat) : Char :=
  if n < 10 then
    Char.ofNat (48 + n)
  else
    Char.ofNat (87 + n)

private def hexByte (byte : UInt8) : String :=
  let n := byte.toNat
  String.singleton (hexDigit (n / 16)) ++ String.singleton (hexDigit (n % 16))

def utf8Hex (bytes : ByteArray) : String :=
  String.intercalate " " <| Id.run do
    let mut parts : Array String := #[]
    for byte in bytes do
      parts := parts.push (hexByte byte)
    return parts.toList

def bundleWorkspaceOwnerMarkerName : String :=
  ".lean-beam-bundle-workspace"

def bundleWorkspaceFor (bundleDir : System.FilePath) : System.FilePath :=
  bundleDir / "workspace"

def bundleWorkspaceOwnerMarker (workspace : System.FilePath) : System.FilePath :=
  workspace / bundleWorkspaceOwnerMarkerName

def bundlePathsFor (workspace : System.FilePath) : BundlePaths :=
  {
    daemon := workspace / ".lake" / "build" / "bin" / "beam-daemon"
    client := workspace / ".lake" / "build" / "bin" / "beam-client"
    plugin := RunAt.Lib.pluginSharedLibPath (workspace / ".lake" / "build" / "lib")
  }

end Beam.Cli
