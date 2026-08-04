/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Lock
import Beam.LSP.Lib.NativeLib

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
  let installedPlugin := Beam.LSP.Lib.pluginSharedLibPath (home / "libexec")
  let checkoutDaemon := home / ".lake" / "build" / "bin" / "beam-daemon"
  let checkoutClient := home / ".lake" / "build" / "bin" / "beam-client"
  let checkoutPlugin := Beam.LSP.Lib.pluginSharedLibPath (home / ".lake" / "build" / "lib")
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
  ensurePathExists "Beam LSP plugin" paths.plugin

def beamStateDirName : String :=
  ".beam"

def installBundlesDirName : String :=
  "install-bundles"

def runtimeBundlesDirName : String :=
  "bundles"

def beamStateDir (root : System.FilePath) : System.FilePath :=
  root / beamStateDirName

def skillInstallBundleCacheRoot (agentHome : System.FilePath) : System.FilePath :=
  agentHome / "skills" / "lean-beam" / beamStateDirName / installBundlesDirName

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
  | none => pure (beamStateDir root / runtimeBundlesDirName)

def supportedLeanToolchainsPath (home : System.FilePath) : System.FilePath :=
  home / "supported-lean-toolchains"

def compatibleLeanReleaseLinesPath (home : System.FilePath) : System.FilePath :=
  home / "compatible-lean-release-lines"

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

def canonicalLeanToolchainPrefix : String :=
  "leanprover/lean4:v"

private def canonicalNat? (text : String) : Option Nat := do
  let value ← text.toNat?
  if s!"{value}" == text then some value else none

structure LeanReleaseLine where
  major : Nat
  minor : Nat
  deriving BEq, Repr

def LeanReleaseLine.versionText (line : LeanReleaseLine) : String :=
  s!"{line.major}.{line.minor}"

def LeanReleaseLine.registryEntry (line : LeanReleaseLine) : String :=
  canonicalLeanToolchainPrefix ++ line.versionText

def parseLeanReleaseLine? (text : String) : Option LeanReleaseLine := do
  unless text.startsWith canonicalLeanToolchainPrefix do
    none
  let versionText := (text.drop canonicalLeanToolchainPrefix.length).toString
  let [majorText, minorText] := versionText.splitOn "."
    | none
  let major ← canonicalNat? majorText
  let minor ← canonicalNat? minorText
  let line : LeanReleaseLine := { major, minor }
  if line.registryEntry == text then some line else none

structure CanonicalLeanToolchain where
  releaseLine : LeanReleaseLine
  patch : Nat
  rc? : Option Nat := none
  deriving BEq, Repr

def CanonicalLeanToolchain.versionText (toolchain : CanonicalLeanToolchain) : String :=
  let stable := s!"{toolchain.releaseLine.versionText}.{toolchain.patch}"
  match toolchain.rc? with
  | some rc => s!"{stable}-rc{rc}"
  | none => stable

def CanonicalLeanToolchain.name (toolchain : CanonicalLeanToolchain) : String :=
  canonicalLeanToolchainPrefix ++ toolchain.versionText

private def parseLeanPrerelease? (text : String) : Option Nat := do
  unless text.startsWith "rc" do
    none
  let numberText := (text.drop 2).toString
  let rc ← canonicalNat? numberText
  if rc > 0 && s!"rc{rc}" == text then some rc else none

private def parseCanonicalLeanVersion?
    (versionText : String)
    (rc? : Option Nat) : Option CanonicalLeanToolchain := do
  let [majorText, minorText, patchText] := versionText.splitOn "."
    | none
  let major ← canonicalNat? majorText
  let minor ← canonicalNat? minorText
  let patch ← canonicalNat? patchText
  some { releaseLine := { major, minor }, patch, rc? }

def parseCanonicalLeanToolchain? (text : String) : Option CanonicalLeanToolchain := do
  unless text.startsWith canonicalLeanToolchainPrefix do
    none
  let versionText := (text.drop canonicalLeanToolchainPrefix.length).toString
  let parsed ←
    match versionText.splitOn "-" with
    | [stable] => parseCanonicalLeanVersion? stable none
    | [stable, prerelease] => do
        let rc ← parseLeanPrerelease? prerelease
        parseCanonicalLeanVersion? stable (some rc)
    | _ => none
  if parsed.name == text then some parsed else none

def compatibleLeanReleaseLines (home : System.FilePath) : IO (System.FilePath × List LeanReleaseLine) := do
  let path := compatibleLeanReleaseLinesPath home
  unless ← path.pathExists do
    throw <| IO.userError s!"missing compatible Lean release-line registry at {path}"
  let mut lines := []
  for entry in nonCommentLines (← IO.FS.readFile path) do
    let some line := parseLeanReleaseLine? entry
      | throw <| IO.userError s!"invalid compatible Lean release line in {path}: {entry}"
    if lines.elem line then
      throw <| IO.userError s!"duplicate compatible Lean release line in {path}: {entry}"
    lines := lines ++ [line]
  pure (path, lines)

def customLeanToolchains (home : System.FilePath) : IO (System.FilePath × List String) := do
  let path := customLeanToolchainsPath home
  unless ← path.pathExists do
    return (path, [])
  pure (path, nonCommentLines (← IO.FS.readFile path))

inductive LeanToolchainAcceptance where
  | validated
  | releaseLine (line : LeanReleaseLine)
  | custom
  | unsupported
  deriving BEq, Repr

def LeanToolchainAcceptance.accepted : LeanToolchainAcceptance → Bool
  | .validated => true
  | .releaseLine _ => true
  | .custom => true
  | .unsupported => false

def LeanToolchainAcceptance.label : LeanToolchainAcceptance → String
  | .validated => "validated"
  | .releaseLine _ => "release-line"
  | .custom => "custom"
  | .unsupported => "unsupported"

def LeanToolchainAcceptance.releaseLine? : LeanToolchainAcceptance → Option LeanReleaseLine
  | .releaseLine line => some line
  | _ => none

structure LeanToolchainSupport where
  validatedPath : System.FilePath
  validatedToolchains : List String
  compatiblePath : System.FilePath
  compatibleReleaseLines : List LeanReleaseLine
  customPath : System.FilePath
  customToolchains : List String
  acceptance : LeanToolchainAcceptance
  deriving Repr

def leanToolchainSupport (home : System.FilePath) (toolchain : String) : IO LeanToolchainSupport := do
  let (validatedPath, validatedToolchains) ← supportedLeanToolchains home
  let (compatiblePath, compatibleReleaseLines) ← compatibleLeanReleaseLines home
  let (customPath, customToolchains) ← customLeanToolchains home
  let acceptance :=
    if validatedToolchains.elem toolchain then
      .validated
    else
      match parseCanonicalLeanToolchain? toolchain with
      | some canonical =>
          if compatibleReleaseLines.elem canonical.releaseLine then
            .releaseLine canonical.releaseLine
          else if customToolchains.elem toolchain then
            .custom
          else
            .unsupported
      | none =>
          if customToolchains.elem toolchain then .custom else .unsupported
  pure {
    validatedPath
    validatedToolchains
    compatiblePath
    compatibleReleaseLines
    customPath
    customToolchains
    acceptance
  }

def ensureAcceptedLeanToolchain (home : System.FilePath) (toolchain : String) : IO Unit := do
  let support ← leanToolchainSupport home toolchain
  unless support.acceptance.accepted do
    throw <| IO.userError <| String.intercalate "\n" [
      s!"unsupported Lean toolchain: {toolchain}",
      s!"validated toolchain registry: {support.validatedPath}",
      s!"compatible release-line registry: {support.compatiblePath}",
      s!"custom toolchain registry: {support.customPath}",
      "run `lean-beam supported-toolchains` to list the validated toolchains",
      "run `lean-beam compatible-release-lines` to list canonical RC and patch release lines",
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
    plugin := Beam.LSP.Lib.pluginSharedLibPath (workspace / ".lake" / "build" / "lib")
  }

end Beam.Cli
