/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.InstallLayout
import Beam.Cli.Lock
import RunAt.Lib.NativeLib

open Lean

namespace Beam.Cli

structure BundlePaths where
  daemon : System.FilePath
  client : System.FilePath
  plugin : System.FilePath
  deriving Repr

def bundleMetadataSchemaVersion : Nat := 1

private structure BundleMetadata where
  schemaVersion : Nat
  toolchain : String
  sourceHash : String
  workspace : String
  builtAt : String
  deriving FromJson, ToJson

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

def nonCommentLines (text : String) : List String :=
  (text.splitOn "\n").filterMap fun raw =>
    let line := trimLine raw
    if line.isEmpty || line.startsWith "#" then none else some line

def supportedLeanToolchains (home : System.FilePath) : IO (System.FilePath × List String) := do
  let path := supportedLeanToolchainsPath home
  unless ← path.pathExists do
    throw <| IO.userError s!"missing supported Lean toolchain registry at {path}"
  pure (path, nonCommentLines (← IO.FS.readFile path))

def ensureSupportedLeanToolchain (home : System.FilePath) (toolchain : String) : IO Unit := do
  let (path, toolchains) ← supportedLeanToolchains home
  unless toolchains.elem toolchain do
    throw <| IO.userError <| String.intercalate "\n" [
      s!"unsupported Lean toolchain: {toolchain}",
      s!"supported toolchain registry: {path}",
      "run `lean-beam supported-toolchains` to list the validated toolchains"
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

def bundleWorkspaceFor (bundleDir : System.FilePath) : System.FilePath :=
  bundleDir / "workspace"

def bundlePathsFor (workspace : System.FilePath) : BundlePaths :=
  {
    daemon := workspace / ".lake" / "build" / "bin" / "beam-daemon"
    client := workspace / ".lake" / "build" / "bin" / "beam-client"
    plugin := RunAt.Lib.pluginSharedLibPath (workspace / ".lake" / "build" / "lib")
  }

def bundleArtifactsReady (workspace : System.FilePath) : IO Bool := do
  let paths := bundlePathsFor workspace
  return (← paths.daemon.pathExists) && (← paths.client.pathExists) && (← paths.plugin.pathExists)

def bundleMetadataPath (bundleDir : System.FilePath) : System.FilePath :=
  bundleDir / "metadata.json"

def bundlePlatform : IO String := do
  let system := ← readCmdTrim "uname" #["-s"]
  let machine := ← readCmdTrim "uname" #["-m"]
  pure s!"{system.toLower}-{machine.toLower}"

def hashByte (acc : UInt64) (byte : UInt8) : UInt64 :=
  (acc ^^^ byte.toUInt64) * 1099511628211

def hashBytes (bytes : ByteArray) (init : UInt64 := 14695981039346656037) : UInt64 :=
  bytes.foldl hashByte init

def hashString (text : String) (init : UInt64 := 14695981039346656037) : UInt64 :=
  hashBytes text.toUTF8 init

def mixField (acc : UInt64) (text : String) : UInt64 :=
  hashString text <| hashByte acc 0

private partial def collectTreeFiles (current : System.FilePath) : IO (Array System.FilePath) := do
  let entries := (← current.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut files := #[]
  for entry in entries do
    if ← entry.path.isDir then
      files := files ++ (← collectTreeFiles entry.path)
    else
      files := files.push entry.path
  pure files

def relativePathString (root path : System.FilePath) : String :=
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
  if pathStr.startsWith rootPrefix then
    (pathStr.drop rootPrefix.length).toString
  else
    pathStr

def sortedPaths (paths : Array System.FilePath) : Array System.FilePath :=
  paths.qsort (fun a b => a.toString < b.toString)

def collectBundleSourceFiles (root : System.FilePath) : IO (Array System.FilePath) := do
  let mut files := #[]
  for name in bundleRootFiles do
    let path := root / name
    if ← path.pathExists then
      files := files.push path
  for dirName in bundleSourceDirs do
    let dir := root / dirName
    if ← dir.pathExists then
      files := files ++ (← collectTreeFiles dir)
  pure <| sortedPaths files

private def mixFileHash (acc : UInt64) (root path : System.FilePath) : IO UInt64 := do
  let rel := relativePathString root path
  let acc := mixField acc rel
  let bytes ← IO.FS.readBinFile path
  pure <| hashBytes bytes <| hashByte acc 0

def sourceHash (home : System.FilePath) : IO String := do
  let root ← IO.FS.realPath home
  let files ← collectBundleSourceFiles root
  let mut acc : UInt64 := 14695981039346656037
  for path in files do
    acc ← mixFileHash acc root path
  pure s!"{acc.toNat}"

def bundleIdFor (toolchain source platformKey : String) : String :=
  s!"{mixField (mixField (mixField 14695981039346656037 toolchain) source) platformKey |>.toNat}"

def bundleDirFor (cacheRoot home : System.FilePath) (toolchain : String) : IO (System.FilePath × String × String) := do
  let platformKey ← bundlePlatform
  let srcHash ← sourceHash home
  let bundleId := bundleIdFor toolchain srcHash platformKey
  pure (cacheRoot / platformKey / bundleId, bundleId, srcHash)

private def copyFileInto (srcRoot dstRoot srcPath : System.FilePath) : IO Unit := do
  let rel := relativePathString srcRoot srcPath
  let dst := dstRoot / rel
  if let some parent := dst.parent then
    IO.FS.createDirAll parent
  IO.FS.writeBinFile dst (← IO.FS.readBinFile srcPath)

private def copyTreeInto (srcRoot dstRoot : System.FilePath) : IO Unit := do
  let files ← collectTreeFiles srcRoot
  for path in files do
    copyFileInto srcRoot dstRoot path

def syncBundleWorkspace (home workspace : System.FilePath) : IO Unit := do
  if ← workspace.pathExists then
    IO.FS.removeDirAll workspace
  IO.FS.createDirAll workspace
  let files ← collectBundleSourceFiles home
  for path in files do
    copyFileInto home workspace path
  let packagesDir := home / ".lake" / "packages"
  if ← packagesDir.pathExists then
    copyTreeInto packagesDir (workspace / ".lake" / "packages")

def bundleMetadataJson
    (toolchain srcHash : String)
    (workspace : System.FilePath)
    (builtAt : String) : Json :=
  toJson ({
    schemaVersion := bundleMetadataSchemaVersion
    toolchain
    sourceHash := srcHash
    workspace := workspace.toString
    builtAt
  } : BundleMetadata)

def checkBundleMetadataJson
    (toolchain srcHash : String)
    (_workspace : System.FilePath)
    (json : Json) : Except String Unit := do
  let metadata : BundleMetadata ← fromJson? json
  if metadata.schemaVersion != bundleMetadataSchemaVersion then
    throw s!"unsupported bundle metadata schemaVersion {metadata.schemaVersion}"
  if metadata.toolchain != toolchain then
    throw s!"bundle metadata toolchain mismatch: expected {toolchain}, got {metadata.toolchain}"
  if metadata.sourceHash != srcHash then
    throw s!"bundle metadata sourceHash mismatch: expected {srcHash}, got {metadata.sourceHash}"
  if metadata.workspace.isEmpty then
    throw "bundle metadata workspace must not be empty"
  if metadata.builtAt.isEmpty then
    throw "bundle metadata builtAt must not be empty"

def bundleMetadataReady
    (bundleDir : System.FilePath)
    (toolchain srcHash : String)
    (workspace : System.FilePath) : IO Bool := do
  let path := bundleMetadataPath bundleDir
  unless ← path.pathExists do
    return false
  try
    let json ← IO.ofExcept <| Json.parse (← IO.FS.readFile path)
    match checkBundleMetadataJson toolchain srcHash workspace json with
    | .ok _ => return true
    | .error _ => return false
  catch _ =>
    return false

def bundleReady (bundleDir : System.FilePath) (toolchain srcHash : String) : IO Bool := do
  let workspace := bundleWorkspaceFor bundleDir
  return (← bundleArtifactsReady workspace) && (← bundleMetadataReady bundleDir toolchain srcHash workspace)

private def writeBundleMetadata (bundleDir : System.FilePath) (toolchain srcHash : String) (workspace : System.FilePath) : IO Unit := do
  let path := bundleMetadataPath bundleDir
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path ((bundleMetadataJson toolchain srcHash workspace (← utcTimestamp)).pretty ++ "\n")

private def ensureElan : IO Unit := do
  unless ← commandAvailable "elan" do
    throw <| IO.userError "missing elan on PATH"

private def fallbackBuildFailureMessage (toolchain : String) (cacheRoot bundleDir : System.FilePath)
    (stderr : String) : String :=
  String.intercalate "\n" [
    s!"failed to build local beam fallback bundle for toolchain {toolchain}",
    s!"install bundle cache did not provide a matching bundle; attempted local fallback under {cacheRoot}",
    s!"bundle workspace: {bundleWorkspaceFor bundleDir}",
    "this fallback path runs `lake build` and may need network access on a cold machine if dependencies have not been fetched yet",
    "if you want to avoid that at runtime, prebuild the installed skill bundle for the supported toolchain first",
    "",
    "lake stderr:",
    stderr
  ]

def buildToolchainBundle (home : System.FilePath) (toolchain srcHash : String)
    (cacheRoot bundleDir workspace : System.FilePath) : IO Unit := do
  ensureElan
  syncBundleWorkspace home workspace
  IO.eprintln s!"building beam bundle for {toolchain}"
  let out ← IO.Process.output {
    cmd := "elan"
    args := #["run", toolchain, "lake", "build", "RunAt:shared", "beam-daemon", "beam-client"]
    cwd := workspace.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError <| fallbackBuildFailureMessage toolchain cacheRoot bundleDir out.stderr
  writeBundleMetadata bundleDir toolchain srcHash workspace

def existingToolchainBundle? (cacheRoot home : System.FilePath) (toolchain : String) : IO (Option (BundlePaths × String)) := do
  let (bundleDir, bundleId, srcHash) ← bundleDirFor cacheRoot home toolchain
  let workspace := bundleWorkspaceFor bundleDir
  if ← bundleReady bundleDir toolchain srcHash then
    pure <| some (bundlePathsFor workspace, bundleId)
  else
    pure none

partial def existingToolchainBundleInAny? (cacheRoots : List System.FilePath) (home : System.FilePath)
    (toolchain : String) : IO (Option (BundlePaths × String)) := do
  match cacheRoots with
  | [] => pure none
  | cacheRoot :: rest =>
      match ← existingToolchainBundle? cacheRoot home toolchain with
      | some bundle => pure <| some bundle
      | none => existingToolchainBundleInAny? rest home toolchain

def ensureToolchainBundleIn (cacheRoot home : System.FilePath) (toolchain : String) : IO (BundlePaths × String) := do
  ensureSupportedLeanToolchain home toolchain
  let (bundleDir, bundleId, srcHash) ← bundleDirFor cacheRoot home toolchain
  let workspace := bundleWorkspaceFor bundleDir
  withLock (bundleDir / "lock") do
    unless ← bundleReady bundleDir toolchain srcHash do
      buildToolchainBundle home toolchain srcHash cacheRoot bundleDir workspace
  pure (bundlePathsFor workspace, bundleId)

def ensureToolchainBundle (root home : System.FilePath) (toolchain : String) : IO (BundlePaths × String) := do
  ensureSupportedLeanToolchain home toolchain
  match ← existingToolchainBundleInAny? (← installBundleCacheRoots) home toolchain with
  | some bundle => pure bundle
  | none =>
      let cacheRoot ← runtimeBundleCacheRoot root
      ensureToolchainBundleIn cacheRoot home toolchain

def ensureDefaultDaemonHelpers (home : System.FilePath) : IO BundlePaths := do
  let paths ← defaultBundlePaths home
  if (← paths.daemon.pathExists) && (← paths.client.pathExists) then
    pure paths
  else
    let out ← IO.Process.output {
      cmd := "lake"
      args := #["build", "beam-daemon", "beam-client"]
      cwd := home.toString
    }
    if out.exitCode != 0 then
      throw <| IO.userError s!"failed to build default Beam daemon helpers\n{out.stderr}"
    ensureBundleExists paths
    pure paths

def predictedToolchainBundle (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (BundlePaths × String) := do
  let (bundleDir, bundleId, _) ← bundleDirFor cacheRoot home toolchain
  pure (bundlePathsFor (bundleWorkspaceFor bundleDir), bundleId)

end Beam.Cli
