/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Daemon
import Beam.Cli.Lock
import Beam.Cli.RuntimeBundle

open Lean

namespace RunAtTest.Broker.CliDaemonTest

private def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

private def checkStartupRetryPolicy : IO Unit := do
  require "automatic occupied endpoint should retry"
    (Beam.Cli.shouldRetryAutomaticStartup true 1 true)
  require "automatic endpoint should not retry after attempts are exhausted"
    (!Beam.Cli.shouldRetryAutomaticStartup true 0 true)
  require "automatic endpoint should not retry when endpoint is not occupied after failure"
    (!Beam.Cli.shouldRetryAutomaticStartup true 1 false)
  require "explicit endpoint should not retry"
    (!Beam.Cli.shouldRetryAutomaticStartup false 1 true)

private def checkLockLifecycle : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-cli-lock-test-{← IO.monoNanosNow}"
  let lockDir := root / "lock"
  try
    Beam.Cli.withLock lockDir do
      require "lock directory should exist while lock is held" (← lockDir.pathExists)
      require "lock pid file should exist while lock is held" (← (lockDir / "pid").pathExists)
    require "lock directory should be removed after release" (!(← lockDir.pathExists))

    IO.FS.createDirAll lockDir
    IO.FS.writeFile (lockDir / "pid") "999999999\n"
    Beam.Cli.withLock lockDir do
      let pidText := (← IO.FS.readFile (lockDir / "pid")).trimAscii.toString
      require "stale lock should be replaced with this process lock" (pidText != "999999999")
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def writeFakeBundleArtifacts (workspace : System.FilePath) : IO Unit := do
  let paths := Beam.Cli.bundlePathsFor workspace
  for path in #[paths.daemon, paths.client, paths.plugin] do
    if let some parent := path.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile path "fake artifact\n"

private def writeBundleMetadataFile
    (bundleDir : System.FilePath)
    (toolchain sourceHash : String)
    (workspace : System.FilePath) : IO Unit := do
  IO.FS.writeFile
    (Beam.Cli.bundleMetadataPath bundleDir)
    ((Beam.Cli.bundleMetadataJson toolchain sourceHash workspace "2026-06-05T00:00:00Z").pretty ++ "\n")

private def checkRuntimeBundleHelpers : IO Unit := do
  let id := Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" "source-a" "linux-x86_64"
  require "bundle id should be deterministic"
    (id == Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" "source-a" "linux-x86_64")
  require "bundle id should include platform"
    (id != Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" "source-a" "darwin-arm64")
  require "bundle id should include source hash"
    (id != Beam.Cli.bundleIdFor "leanprover/lean4:v4.30.0" "source-b" "linux-x86_64")

  let workspace := System.FilePath.mk "/tmp/beam-runtime-bundle-workspace"
  let paths := Beam.Cli.bundlePathsFor workspace
  require "bundle daemon path should point at workspace build output"
    (paths.daemon == workspace / ".lake" / "build" / "bin" / "beam-daemon")
  require "bundle client path should point at workspace build output"
    (paths.client == workspace / ".lake" / "build" / "bin" / "beam-client")
  require "bundle plugin path should live under workspace build lib"
    (paths.plugin.toString.startsWith (workspace / ".lake" / "build" / "lib").toString)
  require "state directory should remain the public .beam path"
    (Beam.Cli.runAtStateDir (System.FilePath.mk "/tmp/project") == System.FilePath.mk "/tmp/project" / ".beam")

  let metadata := Beam.Cli.bundleMetadataJson
    "leanprover/lean4:v4.30.0"
    "source-a"
    workspace
    "2026-06-05T00:00:00Z"
  let schemaVersion ← IO.ofExcept <| metadata.getObjValAs? Nat "schemaVersion"
  let toolchain ← IO.ofExcept <| metadata.getObjValAs? String "toolchain"
  let sourceHash ← IO.ofExcept <| metadata.getObjValAs? String "sourceHash"
  let metadataWorkspace ← IO.ofExcept <| metadata.getObjValAs? String "workspace"
  require "bundle metadata schema version should remain explicit"
    (schemaVersion == Beam.Cli.bundleMetadataSchemaVersion)
  require "bundle metadata should include toolchain" (toolchain == "leanprover/lean4:v4.30.0")
  require "bundle metadata should include source hash" (sourceHash == "source-a")
  require "bundle metadata should include workspace" (metadataWorkspace == workspace.toString)

private def checkRuntimeBundleMetadataAcceptance : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-runtime-bundle-ready-test-{← IO.monoNanosNow}"
  let bundleDir := root / "bundle"
  let workspace := Beam.Cli.bundleWorkspaceFor bundleDir
  let toolchain := "leanprover/lean4:v4.30.0"
  let sourceHash := "source-a"
  try
    writeFakeBundleArtifacts workspace

    require "bundle should reject artifacts without metadata"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash))

    let invalidSchema := Json.mkObj [
      ("schemaVersion", toJson 0),
      ("toolchain", toJson toolchain),
      ("sourceHash", toJson sourceHash),
      ("workspace", toJson workspace.toString),
      ("builtAt", toJson "2026-06-05T00:00:00Z")
    ]
    IO.FS.writeFile (Beam.Cli.bundleMetadataPath bundleDir) (invalidSchema.pretty ++ "\n")
    require "bundle should reject unsupported metadata schema"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash))

    writeBundleMetadataFile bundleDir toolchain "source-b" workspace
    require "bundle should reject stale source metadata"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash))

    writeBundleMetadataFile bundleDir toolchain sourceHash workspace
    require "bundle should accept matching artifacts and metadata"
      (← Beam.Cli.bundleReady bundleDir toolchain sourceHash)

    writeBundleMetadataFile bundleDir toolchain sourceHash (System.FilePath.mk <| "/private" ++ workspace.toString)
    require "bundle should accept metadata with equivalent diagnostic workspace spelling"
      (← Beam.Cli.bundleReady bundleDir toolchain sourceHash)

    IO.FS.removeFile (Beam.Cli.bundlePathsFor workspace).client
    require "bundle should reject matching metadata without required artifacts"
      (!(← Beam.Cli.bundleReady bundleDir toolchain sourceHash))
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

def main : IO Unit := do
  checkStartupRetryPolicy
  checkLockLifecycle
  checkRuntimeBundleHelpers
  checkRuntimeBundleMetadataAcceptance

end RunAtTest.Broker.CliDaemonTest

def main := RunAtTest.Broker.CliDaemonTest.main
