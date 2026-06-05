/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Daemon
import Beam.Cli.Lock
import Beam.Cli.RuntimeBundle

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

def main : IO Unit := do
  checkStartupRetryPolicy
  checkLockLifecycle
  checkRuntimeBundleHelpers

end RunAtTest.Broker.CliDaemonTest

def main := RunAtTest.Broker.CliDaemonTest.main
