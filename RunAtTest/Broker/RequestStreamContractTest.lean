/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import RunAtTest.Broker.TestUtil
import RunAtTest.TodoFixture
import Lean

open Lean

namespace RunAtTest.Broker.RequestStreamContractTest

open RunAtTest.Broker.TestUtil

private structure StreamRun where
  exitCode : UInt32
  stderr : String
  messages : Array Beam.Broker.StreamMessage

private def buildLakeTarget (root : System.FilePath) (target : String) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "env"
    args := #["LAKE_ARTIFACT_CACHE=false", "lake", "--no-cache", "build", target]
    cwd := root.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to build {target} in {root}\n{out.stderr}"

private def decodeStreamLines (output : String) : IO (Array Beam.Broker.StreamMessage) := do
  let lines :=
    output.split (· == '\n') |>.filterMap fun line =>
      let line := line.trimAscii.toString
      if line.isEmpty then none else some line
  if lines.isEmpty then
    throw <| IO.userError "expected request-stream output"
  lines.toArray.mapM fun line =>
    match Json.parse line with
    | .error err => throw <| IO.userError s!"invalid request-stream json line: {err}\n{line}"
    | .ok json =>
        IO.ofExcept <| fromJson? json

private def runRequestStream
    (port : UInt16)
    (req : Beam.Broker.Request) : IO StreamRun := do
  let out ← IO.Process.output {
    cmd := (← clientExe).toString
    args := #["--port", toString port.toNat, "request-stream", (toJson req).compress]
  }
  let messages ← decodeStreamLines out.stdout
  pure {
    exitCode := out.exitCode
    stderr := out.stderr
    messages
  }

private def requireSuccessStream (label : String) (run : StreamRun) : IO (Array Beam.Broker.StreamMessage) := do
  if run.exitCode != 0 then
    throw <| IO.userError s!"expected {label} request-stream success, got exit {run.exitCode}\nstderr:\n{run.stderr}"
  unless run.stderr.trimAscii.toString.isEmpty do
    throw <| IO.userError s!"expected {label} request-stream stderr to stay empty, got:\n{run.stderr}"
  pure run.messages

private def requireFailedStream (label : String) (run : StreamRun) : IO (Array Beam.Broker.StreamMessage) := do
  if run.exitCode == 0 then
    throw <| IO.userError s!"expected {label} request-stream failure"
  unless run.stderr.trimAscii.toString.isEmpty do
    throw <| IO.userError s!"expected {label} request-stream stderr to stay empty, got:\n{run.stderr}"
  pure run.messages

private def expectErrorCode (label code : String) (resp : Beam.Broker.Response) : IO Unit := do
  if resp.ok then
    throw <| IO.userError s!"expected {label} error {code}, got success {(toJson resp).compress}"
  let actual := resp.error?.map (·.code)
  if actual != some code then
    throw <| IO.userError s!"expected {label} error {code}, got {(toJson resp).compress}"
  if resp.result?.isSome then
    throw <| IO.userError s!"expected {label} error response to omit result payload, got {(toJson resp).compress}"

private def expectTodoKindOnly
    (label : String)
    (kind : RunAt.TodoKind)
    (result : RunAt.TodoResult) : IO RunAt.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind)
    | throw <| IO.userError s!"expected {label} to contain todo kind {kind.key}, got {(toJson result).compress}"
  if result.items.any (fun item => item.kind != kind) then
    throw <| IO.userError s!"expected {label} to contain only todo kind {kind.key}, got {(toJson result).compress}"
  pure item

def main : IO Unit := do
  let port ← freshTcpPort
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← mkTempProjectRoot "beam-daemon-request-stream"
  copySaveProjectFixture root
  let broker ← spawnLeanBroker endpoint root
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint { op := .ensure, root? := some root.toString })

    let todoMessages ← requireSuccessStream "todo" <| ← runRequestStream port {
      op := .todo
      root? := some root.toString
      path? := some RunAtTest.TodoFixture.brokerPath
      line? := some RunAtTest.TodoFixture.startLine
      character? := some RunAtTest.TodoFixture.startCharacter
      endLine? := some RunAtTest.TodoFixture.endLine
      endCharacter? := some RunAtTest.TodoFixture.endCharacter
      kinds? := some #[.sorry]
      suggest? := some .none
    }
    expectStreamKindsOnly "todo" todoMessages
    let todoResp ← requireFinalStreamResponse "todo" todoMessages
    let todoPayload ← expectOk todoResp
    let todoResult : RunAt.TodoResult ← IO.ofExcept <| fromJson? todoPayload
    let todoSorry ← expectTodoKindOnly "todo" .sorry todoResult
    if todoSorry.runAtPosition != RunAtTest.TodoFixture.sorryPosition then
      throw <| IO.userError
        s!"expected todo runAtPosition at {RunAtTest.TodoFixture.sorryPosition}, got {(toJson todoSorry).compress}"

    writeSaveWarningFile root "-- request-stream sync"
    let syncMessages ← requireSuccessStream "sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      fullDiagnostics? := some true
    }
    expectStreamKindsOnly "sync_file" syncMessages
    let syncResp ← requireFinalStreamResponse "sync_file" syncMessages
    let syncPayload ← expectOk syncResp
    expectNoReplayDiagnosticsField "sync_file" syncPayload
    let syncResult : Beam.Broker.SyncFileResult ← IO.ofExcept <| fromJson? syncPayload
    if syncResult.version != 1 then
      throw <| IO.userError s!"expected sync_file version 1, got {syncResult.version}"
    if !syncResult.saveReady then
      throw <| IO.userError s!"expected sync_file saveReady = true, got {(toJson syncResult).compress}"
    if syncResult.stateErrorCount != 0 || syncResult.stateCommandErrorCount != 0 then
      throw <| IO.userError
        s!"expected sync_file state error counts = 0, got {(toJson syncResult).compress}"
    let syncProgress := ← requireAnyStreamFileProgress "sync_file" syncMessages
    let some syncLast := syncProgress.back?
      | throw <| IO.userError "expected sync_file fileProgress tail"
    if !syncLast.done then
      throw <| IO.userError s!"expected sync_file final fileProgress to be done, got {(toJson syncLast).compress}"
    let syncDiagnostics ← requireAnyStreamDiagnostics "sync_file" syncMessages
    expectDiagnosticsForPath "sync_file" "SaveSmoke/B.lean" syncDiagnostics

    writeSaveWarningFile root "-- request-stream save"
    let saveMessages ← requireSuccessStream "save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      fullDiagnostics? := some true
    }
    expectStreamKindsOnly "save_olean" saveMessages
    let saveResp ← requireFinalStreamResponse "save_olean" saveMessages
    let savePayload ← expectOk saveResp
    expectNoReplayDiagnosticsField "save_olean" savePayload
    let saveVersion ← IO.ofExcept <| savePayload.getObjValAs? Nat "version"
    if saveVersion != 2 then
      throw <| IO.userError s!"expected save_olean version 2, got {saveVersion}"
    let saveDiagnostics ← requireAnyStreamDiagnostics "save_olean" saveMessages
    expectNonErrorDiagnosticsForPath "save_olean" "SaveSmoke/B.lean" saveDiagnostics

    writeSaveWarningFile root "-- request-stream close-save"
    let closeMessages ← requireSuccessStream "close-save" <| ← runRequestStream port {
      op := .close
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
      saveArtifacts? := some true
      fullDiagnostics? := some true
    }
    expectStreamKindsOnly "close-save" closeMessages
    let closeResp ← requireFinalStreamResponse "close-save" closeMessages
    let closePayload ← expectOk closeResp
    expectNoReplayDiagnosticsField "close-save" closePayload
    let closed ← IO.ofExcept <| closePayload.getObjValAs? Bool "closed"
    if !closed then
      throw <| IO.userError s!"expected close-save payload to report closed = true, got {closePayload.compress}"
    let savedPayload ← IO.ofExcept <| closePayload.getObjVal? "saved"
    let closeVersion ← IO.ofExcept <| savedPayload.getObjValAs? Nat "version"
    if closeVersion != 3 then
      throw <| IO.userError s!"expected close-save saved version 3, got {closeVersion}"
    let closeDiagnostics ← requireAnyStreamDiagnostics "close-save" closeMessages
    expectNonErrorDiagnosticsForPath "close-save" "SaveSmoke/B.lean" closeDiagnostics

    let standalonePath := root / "StandaloneSaveSmoke.lean"
    IO.FS.writeFile standalonePath "import SaveSmoke.B\n\n#check bVal\n"
    let standaloneSyncMessages ← requireSuccessStream "standalone sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "StandaloneSaveSmoke.lean"
    }
    expectStreamKindsOnly "standalone sync_file" standaloneSyncMessages
    let standaloneSyncResp ← requireFinalStreamResponse "standalone sync_file" standaloneSyncMessages
    discard <| expectOk standaloneSyncResp

    let standaloneSaveMessages ← requireFailedStream "standalone save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "StandaloneSaveSmoke.lean"
    }
    expectStreamKindsOnly "standalone save_olean" standaloneSaveMessages
    let standaloneSaveResp ← requireFinalStreamResponse "standalone save_olean" standaloneSaveMessages
    expectErrorCode "standalone save_olean" Beam.Broker.saveTargetNotModuleCode standaloneSaveResp

    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := \"broken\"\n"
    let brokenSyncMessages ← requireSuccessStream "broken sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
    }
    expectStreamKindsOnly "broken sync_file" brokenSyncMessages
    let brokenSyncResp ← requireFinalStreamResponse "broken sync_file" brokenSyncMessages
    let brokenPayload ← expectOk brokenSyncResp
    expectNoReplayDiagnosticsField "broken sync_file" brokenPayload
    let brokenResult : Beam.Broker.SyncFileResult ← IO.ofExcept <| fromJson? brokenPayload
    if brokenResult.errorCount == 0 || brokenResult.stateErrorCount == 0 then
      throw <| IO.userError
        s!"expected broken sync_file final counts to be nonzero, got {(toJson brokenResult).compress}"
    if brokenResult.saveReady then
      throw <| IO.userError s!"expected broken sync_file saveReady = false, got {(toJson brokenResult).compress}"
    let brokenDiagnostics ← requireAnyStreamDiagnostics "broken sync_file" brokenSyncMessages
    unless brokenDiagnostics.any (fun diagnostic => diagnostic.severity? == some .error) do
      throw <| IO.userError
        s!"expected broken sync_file stream to include an error diagnostic, got {(toJson brokenDiagnostics).compress}"

    let brokenResyncMessages ← requireSuccessStream "unchanged broken sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
    }
    expectStreamKindsOnly "unchanged broken sync_file" brokenResyncMessages
    let brokenResyncResp ← requireFinalStreamResponse "unchanged broken sync_file" brokenResyncMessages
    let brokenResyncPayload ← expectOk brokenResyncResp
    expectNoReplayDiagnosticsField "unchanged broken sync_file" brokenResyncPayload
    let brokenResyncResult : Beam.Broker.SyncFileResult ←
      IO.ofExcept <| fromJson? brokenResyncPayload
    if brokenResyncResult.errorCount == 0 || brokenResyncResult.stateErrorCount == 0 then
      throw <| IO.userError
        s!"expected unchanged broken sync_file final counts to stay nonzero, got {(toJson brokenResyncResult).compress}"
    if brokenResyncResult.saveReady then
      throw <| IO.userError
        s!"expected unchanged broken sync_file saveReady = false, got {(toJson brokenResyncResult).compress}"

    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := 1\n"
    let recoveredSyncMessages ← requireSuccessStream "recovered sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/B.lean"
    }
    expectStreamKindsOnly "recovered sync_file" recoveredSyncMessages
    let recoveredSyncResp ← requireFinalStreamResponse "recovered sync_file" recoveredSyncMessages
    let recoveredPayload ← expectOk recoveredSyncResp
    expectNoReplayDiagnosticsField "recovered sync_file" recoveredPayload
    let recoveredResult : Beam.Broker.SyncFileResult ← IO.ofExcept <| fromJson? recoveredPayload
    if recoveredResult.errorCount != 0 || recoveredResult.stateErrorCount != 0 || !recoveredResult.saveReady then
      throw <| IO.userError
        s!"expected recovered sync_file to be save-ready with zero errors, got {(toJson recoveredResult).compress}"

    buildLakeTarget root "SaveSmoke/A.lean"
    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := \"broken\"\n"

    let staleSyncMessages ← requireFailedStream "stale sync_file" <| ← runRequestStream port {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    expectStreamKindsOnly "stale sync_file" staleSyncMessages
    let staleSyncResp ← requireFinalStreamResponse "stale sync_file" staleSyncMessages
    expectErrorCode "stale sync_file" Beam.Broker.syncBarrierIncompleteCode staleSyncResp

    let staleSaveMessages ← requireFailedStream "stale save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    expectStreamKindsOnly "stale save_olean" staleSaveMessages
    let staleSaveResp ← requireFinalStreamResponse "stale save_olean" staleSaveMessages
    expectErrorCode "stale save_olean" Beam.Broker.syncBarrierIncompleteCode staleSaveResp

    let staleCloseMessages ← requireFailedStream "stale close-save" <| ← runRequestStream port {
      op := .close
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
      saveArtifacts? := some true
    }
    expectStreamKindsOnly "stale close-save" staleCloseMessages
    let staleCloseResp ← requireFinalStreamResponse "stale close-save" staleCloseMessages
    expectErrorCode "stale close-save" Beam.Broker.syncBarrierIncompleteCode staleCloseResp

    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := 1\n"
    buildLakeTarget root "SaveSmoke/A.lean"
    discard <| expectOk <| ← runClient endpoint {
      op := .close
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    let staleTraceSyncResp ← runClient endpoint {
      op := .syncFile
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    discard <| expectOk staleTraceSyncResp
    writeSaveWarningFile root "-- request-stream stale trace"

    let staleTraceSaveMessages ← requireFailedStream "stale trace save_olean" <| ← runRequestStream port {
      op := .saveOlean
      root? := some root.toString
      path? := some "SaveSmoke/A.lean"
    }
    expectStreamKindsOnly "stale trace save_olean" staleTraceSaveMessages
    let staleTraceSaveResp ← requireFinalStreamResponse "stale trace save_olean" staleTraceSaveMessages
    expectErrorCode "stale trace save_olean" Beam.Broker.saveTraceStaleCode staleTraceSaveResp
    discard <| expectOk (← runClient endpoint { op := .stats })

    discard <| expectOk (← runClient endpoint { op := .shutdown })
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    discard <| broker.tryWait
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()

end RunAtTest.Broker.RequestStreamContractTest
