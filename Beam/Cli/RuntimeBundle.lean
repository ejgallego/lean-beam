/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.InstallLayout
import Beam.Cli.Lock
import Beam.Path
import RunAt.Lib.NativeLib

open Lean

namespace Beam.Cli

structure BundlePaths where
  daemon : System.FilePath
  client : System.FilePath
  plugin : System.FilePath
  deriving Repr

def bundleMetadataSchemaVersion : Nat := 2

def bundleWorkspaceOwnerMarkerName : String :=
  ".lean-beam-bundle-workspace"

structure ToolchainFingerprint where
  leanVersion : String
  leanPrefix : String
  leanLibDir : String
  lakeVersion : String
  deriving BEq, Repr, FromJson, ToJson

private structure BundleMetadata where
  schemaVersion : Nat
  toolchain : String
  toolchainFingerprint : ToolchainFingerprint
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
  let rel := Beam.pathRelativeToRootOrSelf root path
  let acc := mixField acc rel
  let bytes ← IO.FS.readBinFile path
  pure <| hashBytes bytes <| hashByte acc 0

def sourceHash (home : System.FilePath) : IO String := do
  let root ← Beam.resolveExistingPath home
  let files ← collectBundleSourceFiles root
  let mut acc : UInt64 := 14695981039346656037
  for path in files do
    acc ← mixFileHash acc root path
  pure s!"{acc.toNat}"

private def ensureElan : IO Unit := do
  unless ← commandAvailable "elan" do
    throw <| IO.userError "missing elan on PATH"

private def readRequiredToolchainCmdTrim (toolchain exe : String) (args : Array String := #[]) :
    IO String := do
  let out ← IO.Process.output {
    cmd := "elan"
    args := #["run", toolchain, exe] ++ args
  }
  if out.exitCode != 0 then
    throw <| IO.userError <| String.intercalate "\n" [
      s!"failed to fingerprint Lean toolchain {toolchain}",
      s!"command: elan run {toolchain} {exe} {String.intercalate " " args.toList}",
      "",
      "stdout:",
      if out.stdout.trimAscii.isEmpty then "(empty)" else out.stdout,
      "",
      "stderr:",
      if out.stderr.trimAscii.isEmpty then "(empty)" else out.stderr
    ]
  let text := trimLine out.stdout
  if text.isEmpty then
    throw <| IO.userError
      s!"failed to fingerprint Lean toolchain {toolchain}: `elan run {toolchain} {exe}` returned empty stdout"
  pure text

def toolchainFingerprintKey (fingerprint : ToolchainFingerprint) : String :=
  String.intercalate "\n" [
    "lean-version", fingerprint.leanVersion,
    "lean-prefix", fingerprint.leanPrefix,
    "lean-libdir", fingerprint.leanLibDir,
    "lake-version", fingerprint.lakeVersion
  ]

def toolchainFingerprintHash (fingerprint : ToolchainFingerprint) : String :=
  s!"{hashString (toolchainFingerprintKey fingerprint) |>.toNat}"

def toolchainFingerprint (toolchain : String) : IO ToolchainFingerprint := do
  ensureElan
  let leanVersion ← readRequiredToolchainCmdTrim toolchain "lean" #["--version"]
  let leanPrefix ← readRequiredToolchainCmdTrim toolchain "lean" #["--print-prefix"]
  let leanLibDir ← readRequiredToolchainCmdTrim toolchain "lean" #["--print-libdir"]
  let lakeVersion ← readRequiredToolchainCmdTrim toolchain "lake" #["--version"]
  pure {
    leanVersion
    leanPrefix
    leanLibDir
    lakeVersion
  }

def bundleIdFor (toolchain : String) (fingerprint : ToolchainFingerprint) (source platformKey : String) :
    String :=
  let acc := mixField 14695981039346656037 toolchain
  let acc := mixField acc (toolchainFingerprintKey fingerprint)
  let acc := mixField acc source
  let acc := mixField acc platformKey
  s!"{acc.toNat}"

def bundleDirForFingerprint (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (System.FilePath × String × String) := do
  let platformKey ← bundlePlatform
  let srcHash ← sourceHash home
  let bundleId := bundleIdFor toolchain fingerprint srcHash platformKey
  pure (cacheRoot / platformKey / bundleId, bundleId, srcHash)

def bundleDirFor (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (System.FilePath × String × String × ToolchainFingerprint) := do
  let fingerprint ← toolchainFingerprint toolchain
  let (bundleDir, bundleId, srcHash) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  pure (bundleDir, bundleId, srcHash, fingerprint)

private def copyFileInto (srcRoot dstRoot srcPath : System.FilePath) : IO Unit := do
  let rel := Beam.pathRelativeToRootOrSelf srcRoot srcPath
  let dst := dstRoot / rel
  if let some parent := dst.parent then
    IO.FS.createDirAll parent
  IO.FS.writeBinFile dst (← IO.FS.readBinFile srcPath)

private def copyTreeInto (srcRoot dstRoot : System.FilePath) : IO Unit := do
  let files ← collectTreeFiles srcRoot
  for path in files do
    copyFileInto srcRoot dstRoot path

private def ensureBundleWorkspaceOwnedForRewrite (bundleDir workspace : System.FilePath) : IO Unit := do
  unless ← workspace.pathExists do
    return ()
  unless ← workspace.isDir do
    throw <| IO.userError s!"refusing to replace non-directory bundle workspace at {workspace}"
  let resolvedBundleDir ← Beam.resolveExistingPath bundleDir
  let resolvedWorkspace ← Beam.resolveExistingPath workspace
  if Beam.pathRelativeToRoot? resolvedBundleDir resolvedWorkspace |>.isNone then
    throw <| IO.userError s!"refusing to rewrite bundle workspace outside its bundle directory: {workspace}"
  unless ← (bundleWorkspaceOwnerMarker workspace).pathExists do
    throw <| IO.userError s!"refusing to remove unmarked existing bundle workspace at {workspace}"

def syncBundleWorkspace (home bundleDir workspace : System.FilePath) : IO Unit := do
  ensureBundleWorkspaceOwnedForRewrite bundleDir workspace
  if ← workspace.pathExists then
    IO.FS.removeDirAll workspace
  IO.FS.createDirAll workspace
  IO.FS.writeFile (bundleWorkspaceOwnerMarker workspace) "owner=lean-beam\nschema=1\n"
  let files ← collectBundleSourceFiles home
  for path in files do
    copyFileInto home workspace path
  let packagesDir := home / ".lake" / "packages"
  if ← packagesDir.pathExists then
    copyTreeInto packagesDir (workspace / ".lake" / "packages")

def bundleMetadataJson
    (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint)
    (workspace : System.FilePath)
    (builtAt : String) : Json :=
  toJson ({
    schemaVersion := bundleMetadataSchemaVersion
    toolchain
    toolchainFingerprint := fingerprint
    sourceHash := srcHash
    workspace := workspace.toString
    builtAt
  } : BundleMetadata)

def checkBundleMetadataJson
    (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint)
    (_workspace : System.FilePath)
    (json : Json) : Except String Unit := do
  let metadata : BundleMetadata ← fromJson? json
  if metadata.schemaVersion != bundleMetadataSchemaVersion then
    throw s!"unsupported bundle metadata schemaVersion {metadata.schemaVersion}"
  if metadata.toolchain != toolchain then
    throw s!"bundle metadata toolchain mismatch: expected {toolchain}, got {metadata.toolchain}"
  if metadata.toolchainFingerprint != fingerprint then
    throw "bundle metadata toolchain fingerprint mismatch"
  if metadata.sourceHash != srcHash then
    throw s!"bundle metadata sourceHash mismatch: expected {srcHash}, got {metadata.sourceHash}"
  if metadata.workspace.isEmpty then
    throw "bundle metadata workspace must not be empty"
  if metadata.builtAt.isEmpty then
    throw "bundle metadata builtAt must not be empty"

def bundleMetadataReady
    (bundleDir : System.FilePath)
    (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint)
    (workspace : System.FilePath) : IO Bool := do
  let path := bundleMetadataPath bundleDir
  unless ← path.pathExists do
    return false
  try
    let json ← IO.ofExcept <| Json.parse (← IO.FS.readFile path)
    match checkBundleMetadataJson toolchain srcHash fingerprint workspace json with
    | .ok _ => return true
    | .error _ => return false
  catch _ =>
    return false

def bundleReady (bundleDir : System.FilePath) (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint) : IO Bool := do
  let workspace := bundleWorkspaceFor bundleDir
  return (← bundleArtifactsReady workspace) &&
    (← bundleMetadataReady bundleDir toolchain srcHash fingerprint workspace)

private def writeBundleMetadata (bundleDir : System.FilePath) (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint) (workspace : System.FilePath) : IO Unit := do
  let path := bundleMetadataPath bundleDir
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path
    ((bundleMetadataJson toolchain srcHash fingerprint workspace (← utcTimestamp)).pretty ++ "\n")

private def samePath (left right : System.FilePath) : IO Bool := do
  try
    let left ← IO.FS.realPath left
    let right ← IO.FS.realPath right
    pure (left.normalize == right.normalize)
  catch _ =>
    pure (left.normalize == right.normalize)

private def symlinkForce (src dst : System.FilePath) : IO Unit := do
  try
    IO.FS.removeFile dst
  catch _ =>
    pure ()
  let out ← IO.Process.output {
    cmd := "ln"
    args := #["-s", src.toString, dst.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to create symlink {dst} -> {src}\n{out.stderr}"

private def copyExecutable (src dst : System.FilePath) : IO Unit := do
  IO.FS.writeBinFile dst (← IO.FS.readBinFile src)
  let x : IO.AccessRight := {read := true, write := true, execution := true}
  let rx : IO.AccessRight := {read := true, write := false, execution := true}
  IO.setAccessRights dst ⟨x, rx, rx⟩

private def prepareNonstandardLakeHome
    (bundleDir leanPrefix libDir : System.FilePath) : IO System.FilePath := do
  if System.Platform.isWindows then
    throw <| IO.userError
      "nonstandard Lean libdir toolchains are not supported by the local bundle fallback on Windows"
  let lakeHome := bundleDir / "lake-home"
  let buildDir := lakeHome / ".lake" / "build"
  let binDir := buildDir / "bin"
  let sharedLibDir := buildDir / "lib"
  let lakeLibDir := sharedLibDir / "lean"
  IO.FS.createDirAll binDir
  IO.FS.createDirAll sharedLibDir
  IO.FS.createDirAll lakeLibDir
  copyExecutable (leanPrefix / "bin" / "lake") (binDir / "lake")
  for entry in ← libDir.readDir do
    let name := entry.fileName
    if name.startsWith "lib" then
      pure ()
    else
      symlinkForce entry.path (lakeLibDir / name)
  let standardLibDir := leanPrefix / "lib" / "lean"
  for entry in ← standardLibDir.readDir do
    let name := entry.fileName
    if name.startsWith "lib" then
      symlinkForce entry.path (sharedLibDir / name)
      symlinkForce entry.path (lakeLibDir / name)
  pure lakeHome

private structure LakeBuildInvocation where
  cmd : String
  args : Array String
  env : Array (String × Option String) := #[]

private def lakeBuildInvocationFor (bundleDir : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) :
    IO LakeBuildInvocation := do
  let default := {
    cmd := "elan",
    args := #["run", toolchain, "lake", "build", "RunAt:shared", "beam-daemon", "beam-client"]
  }
  let leanPrefix := System.FilePath.mk fingerprint.leanPrefix
  let libDir := System.FilePath.mk fingerprint.leanLibDir
  let standardLibDir := leanPrefix / "lib" / "lean"
  if ← samePath libDir standardLibDir then
    pure default
  else
    let lakeHome ← prepareNonstandardLakeHome bundleDir leanPrefix libDir
    pure {
      cmd := (lakeHome / ".lake" / "build" / "bin" / "lake").toString
      args := #["build", "RunAt:shared", "beam-daemon", "beam-client"]
      env := #[
        ("LAKE_HOME", some lakeHome.toString),
        ("LEAN", some (leanPrefix / "bin" / "lean").toString)
      ]
    }

private def fallbackBuildFailureMessage (toolchain : String) (cacheRoot bundleDir : System.FilePath)
    (stdout stderr : String) : String :=
  String.intercalate "\n" [
    s!"failed to build local beam fallback bundle for toolchain {toolchain}",
    s!"install bundle cache did not provide a matching bundle; attempted local fallback under {cacheRoot}",
    s!"bundle workspace: {bundleWorkspaceFor bundleDir}",
    "this fallback path runs `lake build` and may need network access on a cold machine if dependencies have not been fetched yet",
    "if you want to avoid that at runtime, prebuild the installed bundle for the accepted toolchain first",
    "",
    "lake stdout:",
    if stdout.trimAscii.isEmpty then "(empty)" else stdout,
    "",
    "lake stderr:",
    if stderr.trimAscii.isEmpty then "(empty)" else stderr
  ]

def buildToolchainBundle (home : System.FilePath) (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint)
    (cacheRoot bundleDir workspace : System.FilePath) : IO Unit := do
  ensureElan
  syncBundleWorkspace home bundleDir workspace
  IO.eprintln s!"building beam bundle for {toolchain}"
  let lakeBuild ← lakeBuildInvocationFor bundleDir toolchain fingerprint
  let out ← IO.Process.output {
    cmd := lakeBuild.cmd
    args := lakeBuild.args
    env := lakeBuild.env
    cwd := workspace.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError <| fallbackBuildFailureMessage toolchain cacheRoot bundleDir out.stdout out.stderr
  writeBundleMetadata bundleDir toolchain srcHash fingerprint workspace

def existingToolchainBundleForFingerprint? (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (Option (BundlePaths × String)) := do
  let (bundleDir, bundleId, srcHash) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  let workspace := bundleWorkspaceFor bundleDir
  if ← bundleReady bundleDir toolchain srcHash fingerprint then
    pure <| some (bundlePathsFor workspace, bundleId)
  else
    pure none

def existingToolchainBundle? (cacheRoot home : System.FilePath) (toolchain : String) : IO (Option (BundlePaths × String)) := do
  let fingerprint ← toolchainFingerprint toolchain
  existingToolchainBundleForFingerprint? cacheRoot home toolchain fingerprint

partial def existingToolchainBundleInAnyForFingerprint? (cacheRoots : List System.FilePath)
    (home : System.FilePath) (toolchain : String) (fingerprint : ToolchainFingerprint) :
    IO (Option (BundlePaths × String)) := do
  match cacheRoots with
  | [] => pure none
  | cacheRoot :: rest =>
      match ← existingToolchainBundleForFingerprint? cacheRoot home toolchain fingerprint with
      | some bundle => pure <| some bundle
      | none => existingToolchainBundleInAnyForFingerprint? rest home toolchain fingerprint

partial def existingToolchainBundleInAny? (cacheRoots : List System.FilePath) (home : System.FilePath)
    (toolchain : String) : IO (Option (BundlePaths × String)) := do
  match cacheRoots with
  | [] => pure none
  | _ =>
      let fingerprint ← toolchainFingerprint toolchain
      existingToolchainBundleInAnyForFingerprint? cacheRoots home toolchain fingerprint

def ensureToolchainBundleInForFingerprint (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (BundlePaths × String) := do
  let (bundleDir, bundleId, srcHash) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  let workspace := bundleWorkspaceFor bundleDir
  withLock (bundleDir / "lock") do
    unless ← bundleReady bundleDir toolchain srcHash fingerprint do
      buildToolchainBundle home toolchain srcHash fingerprint cacheRoot bundleDir workspace
  pure (bundlePathsFor workspace, bundleId)

def ensureToolchainBundleIn (cacheRoot home : System.FilePath) (toolchain : String) : IO (BundlePaths × String) := do
  ensureAcceptedLeanToolchain home toolchain
  let fingerprint ← toolchainFingerprint toolchain
  ensureToolchainBundleInForFingerprint cacheRoot home toolchain fingerprint

def ensureToolchainBundle (root home : System.FilePath) (toolchain : String) : IO (BundlePaths × String) := do
  ensureAcceptedLeanToolchain home toolchain
  let fingerprint ← toolchainFingerprint toolchain
  match ← existingToolchainBundleInAnyForFingerprint? (← installBundleCacheRoots) home toolchain fingerprint with
  | some bundle => pure bundle
  | none =>
      let cacheRoot ← runtimeBundleCacheRoot root
      ensureToolchainBundleInForFingerprint cacheRoot home toolchain fingerprint

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

def predictedToolchainBundleForFingerprint (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (BundlePaths × String) := do
  let (bundleDir, bundleId, _) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  pure (bundlePathsFor (bundleWorkspaceFor bundleDir), bundleId)

def predictedToolchainBundle (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (BundlePaths × String) := do
  let fingerprint ← toolchainFingerprint toolchain
  predictedToolchainBundleForFingerprint cacheRoot home toolchain fingerprint

end Beam.Cli
