/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Daemon
import Beam.Cli.Broker
import Beam.Cli.LeanOperation
import Beam.Cli.Lock
import Beam.Cli.RuntimeBundle
import Beam.Path
import Beam.Mcp.Projection

open Lean

namespace RunAtTest.Broker.CliDaemonTest

private def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

private def expectIoErrorContains (label needle : String) (act : IO α) : IO Unit := do
  let result ←
    try
      pure <| Except.ok (← act)
    catch err =>
      pure <| Except.error err
  match result with
  | .ok _ =>
      throw <| IO.userError s!"{label}: expected IO error containing {needle}"
  | .error err =>
      unless err.toString.contains needle do
        throw <| IO.userError s!"{label}: expected error containing {needle}, got {err}"

private def requireSubstring (label needle haystack : String) : IO Unit := do
  require s!"{label}: expected '{needle}' in '{haystack}'" (Beam.Cli.hasSubstring haystack needle)

private def requireRequestJson
    (label : String)
    (actual expected : Beam.Broker.Request) : IO Unit := do
  let actualJson := toJson actual
  let expectedJson := toJson expected
  if actualJson != expectedJson then
    throw <| IO.userError s!"{label}: expected {expectedJson.compress}, got {actualJson.compress}"

private def sampleBrokerHandle : Beam.Broker.Handle := {
  backend := .lean
  epoch := 3
  session := "session"
  raw := Json.mkObj [("value", toJson "raw-handle")]
}

private def mcpLeanOperationSurface : Array Beam.Lean.Operation :=
  Beam.Mcp.toolDescriptors.foldl (init := #[]) fun acc desc =>
    match desc.kind with
    | .leanOperation op => acc.push op
    | .workspaceInit => acc

private def requireSameOperationSurface
    (label : String)
    (actual expected : Array Beam.Lean.Operation) : IO Unit := do
  require s!"{label}: expected size {expected.size}, got {actual.size}"
    (actual.size == expected.size)
  for op in expected do
    require s!"{label}: missing operation {repr op}" (actual.contains op)
  for op in actual do
    require s!"{label}: unexpected operation {repr op}" (expected.contains op)

private def checkLeanOperationSurfaceMatrix : IO Unit := do
  requireSameOperationSurface "CLI Lean operation surface"
    Beam.Cli.leanOperationSurface
    Beam.Lean.Operation.all
  requireSameOperationSurface "MCP Lean operation surface"
    mcpLeanOperationSurface
    Beam.Lean.Operation.all
  require "MCP init workspace should stay outside Lean operation surface"
    (Beam.Mcp.ToolName.leanInitWorkspace.kind == .workspaceInit)

private def checkCliRecoveryHints : IO Unit := do
  let staleData := Json.mkObj [
    ("targetPath", toJson "SaveSmoke/A.lean"),
    ("recoveryPlan", toJson #[
      "lean-beam save \"SaveSmoke/B.lean\"",
      "lean-beam refresh \"SaveSmoke/A.lean\"",
      "lake build"
    ])
  ]
  let syncBarrierResp : Beam.Broker.Response := {
    ok := false
    error? := some {
      code := Beam.Broker.syncBarrierIncompleteCode
      message := "Lean diagnostics barrier did not complete"
      data? := some staleData
    }
  }
  let some hint := Beam.Cli.responseRecoveryHint? syncBarrierResp
    | throw <| IO.userError "syncBarrierIncomplete should produce a CLI recovery hint"
  requireSubstring "syncBarrier recovery hint" "lean-beam save \"SaveSmoke/B.lean\"" hint
  requireSubstring "syncBarrier recovery hint" "lean-beam refresh \"SaveSmoke/A.lean\"" hint
  requireSubstring "syncBarrier recovery hint" "lake build" hint

  let fallbackResp : Beam.Broker.Response := {
    ok := false
    error? := some {
      code := Beam.Broker.syncBarrierIncompleteCode
      message := "Lean diagnostics barrier did not complete"
      data? := some <| Json.mkObj [("targetPath", toJson "SaveSmoke/A.lean")]
    }
  }
  let some fallbackHint := Beam.Cli.responseRecoveryHint? fallbackResp
    | throw <| IO.userError "syncBarrierIncomplete fallback should produce a CLI recovery hint"
  requireSubstring "syncBarrier fallback hint" "lean-beam refresh \"SaveSmoke/A.lean\"" fallbackHint
  requireSubstring "syncBarrier fallback hint" "lake build" fallbackHint

  let invalidResp : Beam.Broker.Response := {
    ok := false
    error? := some { code := "invalidParams", message := "bad input" }
  }
  require "invalidParams should not produce a sync recovery hint"
    (Beam.Cli.responseRecoveryHint? invalidResp).isNone

private def checkSyncWaitSpecs : IO Unit := do
  let okResp : Beam.Broker.Response := {
    ok := true
    result? := some <| toJson ({
      version := 5
      saveReady := true
      : Beam.Broker.SyncFileResult
    })
    fileProgress? := some { updates := 2, done := true }
  }
  require "sync complete message should include version and progress"
    ((Beam.Cli.syncWaitSpec "Demo.lean").completeMsg okResp ==
      "beam: sync complete for Demo.lean (version 5, fp updates=2)")
  require "refresh complete message should share sync-like formatting"
    ((Beam.Cli.refreshWaitSpec "Demo.lean").completeMsg okResp ==
      "beam: refresh complete for Demo.lean (version 5, fp updates=2)")

  let notReadyResp : Beam.Broker.Response := {
    ok := true
    result? := some <| toJson ({
      version := 6
      stateErrorCount := 1
      stateCommandErrorCount := 2
      saveReady := false
      saveReadyReason := "documentErrors"
      : Beam.Broker.SyncFileResult
    })
  }
  requireSubstring "sync not-ready message"
    "saveReady=false (documentErrors, stateErrorCount=1, stateCommandErrorCount=2)"
    ((Beam.Cli.syncWaitSpec "Demo.lean").completeMsg notReadyResp)

private def checkLeanOperationRequests : IO Unit := do
  let root := System.FilePath.mk "/repo"
  let rootText := root.toString
  let path := "Demo.lean"

  let runAtInput : Beam.Lean.RunAtInput := {
    path
    line := 4
    character := 2
    text := "exact h"
  }
  requireRequestJson "runAt request should share the Lean operation adapter"
    (Beam.Cli.leanRunAtRequest root path 4 2 (some "exact h"))
    (runAtInput.toBrokerRequest rootText)
  requireRequestJson "runAt handle request should share the Lean operation adapter"
    (Beam.Cli.leanRunAtRequest root path 4 2 (some "exact h") (storeHandle := true))
    (runAtInput.toBrokerRequest rootText (storeHandle := true))
  let missingRunAtText := Beam.Cli.leanRunAtRequest root path 4 2 none
  require "runAt missing text should remain a broker validation error" missingRunAtText.text?.isNone
  require "runAt missing text should still target run_at" (missingRunAtText.op == .runAt)

  let positionInput : Beam.Lean.PositionInput := {
    path
    line := 7
    character := 3
  }
  requireRequestJson "hover request should share the Lean operation adapter"
    (Beam.Cli.leanHoverRequest root path 7 3)
    (positionInput.toHoverBrokerRequest rootText)
  requireRequestJson "goals-after request should share the Lean operation adapter"
    (Beam.Cli.leanGoalsAfterRequest root path 7 3)
    (positionInput.toGoalsBrokerRequest rootText .after)
  requireRequestJson "goals-prev request should share the Lean operation adapter"
    (Beam.Cli.leanGoalsPrevRequest root path 7 3)
    (positionInput.toGoalsBrokerRequest rootText .prev)

  let runWithInput : Beam.Lean.RunWithInput := {
    path
    handle := sampleBrokerHandle
    text := "simp"
  }
  requireRequestJson "runWith request should share the Lean operation adapter"
    (Beam.Cli.leanRunWithRequest root path sampleBrokerHandle (some "simp"))
    (runWithInput.toBrokerRequest rootText)
  requireRequestJson "runWith linear request should share the Lean operation adapter"
    (Beam.Cli.leanRunWithRequest root path sampleBrokerHandle (some "simp") (linear := true))
    (runWithInput.toBrokerRequest rootText (linear := true))
  let missingRunWithText := Beam.Cli.leanRunWithRequest root path sampleBrokerHandle none
  require "runWith missing text should remain a broker validation error" missingRunWithText.text?.isNone
  require "runWith missing text should keep successor-handle semantics"
    (missingRunWithText.storeHandle? == some true)
  require "runWith missing text should keep linear flag explicit"
    (missingRunWithText.linear? == some false)
  require "runWith missing text should keep the supplied handle"
    missingRunWithText.handle?.isSome

  requireRequestJson "release request should share the Lean operation adapter"
    (Beam.Cli.leanReleaseRequest root path sampleBrokerHandle)
    (({ path, handle := sampleBrokerHandle } : Beam.Lean.ReleaseInput).toBrokerRequest rootText)

  let pathInput : Beam.Lean.PathInput := { path }
  requireRequestJson "deps request should share the Lean operation adapter"
    (Beam.Cli.leanDepsRequest root path)
    (pathInput.toDepsBrokerRequest rootText)
  requireRequestJson "close request should share the Lean operation adapter"
    (Beam.Cli.leanCloseRequest root path)
    (pathInput.toCloseBrokerRequest rootText)

  let syncInput : Beam.Lean.SyncInput := { path, fullDiagnostics? := some true }
  requireRequestJson "sync request should share the Lean operation adapter"
    (Beam.Cli.leanSyncRequest root path true)
    (syncInput.toSyncBrokerRequest rootText)
  requireRequestJson "save request should share the Lean operation adapter"
    (Beam.Cli.leanSaveRequest root path true)
    (syncInput.toSaveBrokerRequest rootText)

  let closeSave := Beam.Cli.leanCloseSaveRequest root path true
  require "close-save should use close broker op" (closeSave.op == .close)
  require "close-save should request artifact save" (closeSave.saveArtifacts? == some true)
  require "close-save should preserve full diagnostic flag" (closeSave.fullDiagnostics? == some true)

private def checkStartupRetryPolicy : IO Unit := do
  require "automatic occupied endpoint should retry"
    (Beam.Cli.shouldRetryAutomaticStartup true 1 true false)
  require "automatic startup bind collision should retry"
    (Beam.Cli.shouldRetryAutomaticStartup true 1 false true)
  require "automatic endpoint should not retry after attempts are exhausted"
    (!Beam.Cli.shouldRetryAutomaticStartup true 0 true true)
  require "automatic endpoint should not retry when endpoint is not occupied after failure"
    (!Beam.Cli.shouldRetryAutomaticStartup true 1 false false)
  require "explicit endpoint should not retry"
    (!Beam.Cli.shouldRetryAutomaticStartup false 1 true true)
  require "Linux bind failure wording should be recognized"
    (Beam.Cli.startupFailureSuggestsEndpointInUse "resource busy (error code: 4294967198, address already in use)")
  require "macOS bind failure wording should be recognized"
    (Beam.Cli.startupFailureSuggestsEndpointInUse "Address already in use")

private structure RelativePathCase where
  label : String
  root : System.FilePath
  path : System.FilePath
  expected? : Option String
  display : String

private def checkPathRelativeToRoot : IO Unit := do
  let p := System.FilePath.mk
  let cases : Array RelativePathCase := #[
    {
      label := "root path"
      root := p "/tmp/beam-root"
      path := p "/tmp/beam-root"
      expected? := some "."
      display := "."
    },
    {
      label := "child path"
      root := p "/tmp/beam-root"
      path := p "/tmp/beam-root/src/Main.lean"
      expected? := some "src/Main.lean"
      display := "src/Main.lean"
    },
    {
      label := "sibling prefix trap"
      root := p "/tmp/beam-root"
      path := p "/tmp/beam-root-other/Main.lean"
      expected? := none
      display := "/tmp/beam-root-other/Main.lean"
    },
    {
      label := "outside root"
      root := p "/tmp/beam-root"
      path := p "/tmp/other-root/Main.lean"
      expected? := none
      display := "/tmp/other-root/Main.lean"
    }
  ]
  for c in cases do
    let actual? := Beam.pathRelativeToRoot? c.root c.path
    require s!"{c.label}: expected relative path {repr c.expected?}, got {repr actual?}"
      (actual? == c.expected?)
    let display := Beam.pathRelativeToRootOrSelf c.root c.path
    require s!"{c.label}: expected display path {c.display}, got {display}"
      (display == c.display)

private def checkPathCanonicalization : IO Unit := do
  let stamp ← IO.monoNanosNow
  let root := System.FilePath.mk s!"/tmp/beam-path-canonical-root-{stamp}"
  let alias := System.FilePath.mk s!"/tmp/beam-path-canonical-alias-{stamp}"
  try
    IO.FS.createDirAll root
    let out ← IO.Process.output {
      cmd := "ln"
      args := #["-s", root.toString, alias.toString]
    }
    if out.exitCode != 0 then
      throw <| IO.userError s!"failed to create symlink alias for path canonicalization test\n{out.stderr}"
    require "canonical path equality should treat symlinked workspace roots as the same path"
      (← Beam.sameFilePath root alias)
    require "missing paths should fall back to exact text equality"
      (!(← Beam.sameFilePath (root / "missing") (alias / "missing")))
  finally
    try
      if ← alias.pathExists then
        IO.FS.removeFile alias
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

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

    IO.FS.createDirAll lockDir
    let selfPid ← IO.Process.getPID
    IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
    expectIoErrorContains "live lock timeout" s!"lock owner: pid {selfPid}" <|
      Beam.Cli.withLockTimeout lockDir 100 do
        pure ()
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
  checkLeanOperationSurfaceMatrix
  checkCliRecoveryHints
  checkSyncWaitSpecs
  checkLeanOperationRequests
  checkStartupRetryPolicy
  checkPathRelativeToRoot
  checkPathCanonicalization
  checkLockLifecycle
  checkRuntimeBundleHelpers
  checkRuntimeBundleMetadataAcceptance

end RunAtTest.Broker.CliDaemonTest

def main := RunAtTest.Broker.CliDaemonTest.main
