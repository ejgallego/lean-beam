/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.RuntimeBundle.Fingerprint
import Beam.Cli.RuntimeBundle.Paths

open Lean

namespace Beam.Cli

def bundleMetadataSchemaVersion : Nat := 2

private structure BundleMetadata where
  schemaVersion : Nat
  toolchain : String
  toolchainFingerprint : ToolchainFingerprint
  sourceHash : String
  workspace : String
  builtAt : String
  deriving FromJson, ToJson

def bundleArtifactsReady (workspace : System.FilePath) : IO Bool := do
  let paths := bundlePathsFor workspace
  return (← paths.daemon.pathExists) && (← paths.client.pathExists) && (← paths.plugin.pathExists)

def bundleMetadataPath (bundleDir : System.FilePath) : System.FilePath :=
  bundleDir / "metadata.json"

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

def writeBundleMetadata (bundleDir : System.FilePath) (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint) (workspace : System.FilePath) : IO Unit := do
  let path := bundleMetadataPath bundleDir
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path
    ((bundleMetadataJson toolchain srcHash fingerprint workspace (← utcTimestamp)).pretty ++ "\n")

end Beam.Cli
