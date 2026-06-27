/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import RunAtTest.Broker.RequestStreamUtil
import RunAtTest.Broker.TestUtil

open Lean

namespace RunAtTest.Broker.SyncSummaryDeltaTest

open RunAtTest.Broker.TestUtil

private def requireDiagnosticDelta
    (label : String)
    (summary : Beam.Broker.SyncSummary) : IO Beam.Broker.SyncDiagnosticDelta := do
  let some delta := summary.diagnostics.delta?
    | throw <| IO.userError s!"expected {label} diagnostics.delta, got {(toJson summary).compress}"
  pure delta

private def requireReadinessDelta
    (label : String)
    (summary : Beam.Broker.SyncSummary) : IO Beam.Broker.SyncReadinessDelta := do
  let some delta := summary.readiness.delta?
    | throw <| IO.userError s!"expected {label} readiness.delta, got {(toJson summary).compress}"
  pure delta

private def runSync
    (label : String)
    (port : UInt16)
    (root : System.FilePath) :
    IO (Beam.Broker.SyncFileResult × Beam.Broker.SyncSummary × Array Beam.Broker.StreamMessage) := do
  let messages ← requireSuccessStream label <| ← runRequestStream port {
    op := .syncFile
    root? := some root.toString
    path? := some "SaveSmoke/B.lean"
    fullDiagnostics? := some true
  }
  expectStreamKindsOnly label messages
  let resp ← requireFinalStreamResponse label messages
  let payload ← expectOk resp
  expectNoReplayDiagnosticsField label payload
  let result ← requireSyncFileResult label payload
  let summary := result.syncSummary
  pure (result, summary, messages)

private def checkInitialWarningSync
    (port : UInt16)
    (root : System.FilePath) : IO Beam.Broker.SyncFileResult := do
  writeSaveWarningFile root "-- sync-summary initial warning"
  let (result, summary, messages) ← runSync "initial warning sync_file" port root
  if summary.readiness.current.errorCount != 0 || !summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected initial warning sync_file to be save-ready with zero errors, got {(toJson result).compress}"
  if summary.deltaBaseVersion?.isSome || summary.diagnostics.delta?.isSome ||
      summary.readiness.delta?.isSome then
    throw <| IO.userError
      s!"expected initial warning sync_file to omit delta fields, got {(toJson summary).compress}"
  if summary.diagnostics.current.warning == 0 || summary.readiness.current.warningCount == 0 then
    throw <| IO.userError
      s!"expected initial warning sync_file summary to report warnings, got {(toJson summary).compress}"
  let diagnostics ← requireAnyStreamDiagnostics "initial warning sync_file" messages
  expectWarningDiagnosticPresent "initial warning sync_file" diagnostics
  pure result

private def checkBrokenSync
    (port : UInt16)
    (root : System.FilePath)
    (base : Beam.Broker.SyncFileResult) : IO Beam.Broker.SyncFileResult := do
  IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := \"broken\"\n"
  let (result, summary, messages) ← runSync "broken sync_file" port root
  if result.version <= base.version then
    throw <| IO.userError
      s!"expected broken sync_file to advance from version {base.version}, got {result.version}"
  if summary.readiness.current.errorCount == 0 || summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected broken sync_file to be save-blocked with nonzero save-blocking errors, got {(toJson result).compress}"
  if summary.deltaBaseVersion? != some base.version || !summary.sourceChangedSinceDeltaBase then
    throw <| IO.userError
      s!"expected broken sync_file to delta against changed base version {base.version}, got {(toJson summary).compress}"
  let delta ← requireDiagnosticDelta "broken sync_file" summary
  if delta.added == 0 then
    throw <| IO.userError
      s!"expected broken sync_file diagnostic delta to add an error, got {(toJson delta).compress}"
  let readinessDelta ← requireReadinessDelta "broken sync_file" summary
  if !readinessDelta.saveReadyChanged ||
      !readinessDelta.baseSaveReady ||
      readinessDelta.currentSaveReady then
    throw <| IO.userError
      s!"expected broken sync_file readiness delta to change saveReady true->false, got {(toJson readinessDelta).compress}"
  let diagnostics ← requireAnyStreamDiagnostics "broken sync_file" messages
  unless diagnostics.any (fun diagnostic => diagnostic.severity? == some .error) do
    throw <| IO.userError
      s!"expected broken sync_file stream to include an error diagnostic, got {(toJson diagnostics).compress}"
  pure result

private def checkUnchangedBrokenResync
    (port : UInt16)
    (root : System.FilePath)
    (base : Beam.Broker.SyncFileResult) : IO Beam.Broker.SyncFileResult := do
  let (result, summary, _) ← runSync "unchanged broken sync_file" port root
  if result.version != base.version then
    throw <| IO.userError
      s!"expected unchanged broken sync_file to keep version {base.version}, got {result.version}"
  if summary.readiness.current.errorCount == 0 || summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected unchanged broken sync_file save-blocking counts to stay nonzero, got {(toJson result).compress}"
  if summary.deltaBaseVersion? != some base.version || summary.sourceChangedSinceDeltaBase then
    throw <| IO.userError
      s!"expected unchanged broken sync_file to delta against unchanged version {base.version}, got {(toJson summary).compress}"
  let diagnosticDelta ← requireDiagnosticDelta "unchanged broken sync_file" summary
  if diagnosticDelta.persisted == 0 ||
      diagnosticDelta.added != 0 ||
      diagnosticDelta.removed != 0 then
    throw <| IO.userError
      s!"expected unchanged broken sync_file diagnostic delta to persist the error, got {(toJson diagnosticDelta).compress}"
  let readinessDelta ← requireReadinessDelta "unchanged broken sync_file" summary
  if readinessDelta.saveReadyChanged then
    throw <| IO.userError
      s!"expected unchanged broken sync_file readiness delta to keep saveReady=false, got {(toJson readinessDelta).compress}"
  pure result

private def checkRecoveredSync
    (port : UInt16)
    (root : System.FilePath)
    (base : Beam.Broker.SyncFileResult) : IO Unit := do
  IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := 1\n"
  let (result, summary, _) ← runSync "recovered sync_file" port root
  if result.version <= base.version then
    throw <| IO.userError
      s!"expected recovered sync_file to advance from version {base.version}, got {result.version}"
  if summary.readiness.current.errorCount != 0 || !summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected recovered sync_file to be save-ready with zero errors, got {(toJson result).compress}"
  if summary.deltaBaseVersion? != some base.version || !summary.sourceChangedSinceDeltaBase then
    throw <| IO.userError
      s!"expected recovered sync_file to delta against changed base version {base.version}, got {(toJson summary).compress}"
  let diagnosticDelta ← requireDiagnosticDelta "recovered sync_file" summary
  if diagnosticDelta.removed == 0 then
    throw <| IO.userError
      s!"expected recovered sync_file diagnostic delta to remove the prior error, got {(toJson diagnosticDelta).compress}"
  let readinessDelta ← requireReadinessDelta "recovered sync_file" summary
  if !readinessDelta.saveReadyChanged ||
      readinessDelta.baseSaveReady ||
      !readinessDelta.currentSaveReady then
    throw <| IO.userError
      s!"expected recovered sync_file readiness delta to change saveReady false->true, got {(toJson readinessDelta).compress}"

def main : IO Unit := do
  let port ← freshTcpPort
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← mkTempProjectRoot "beam-sync-summary-delta"
  copySaveProjectFixture root
  let broker ← spawnLeanBroker endpoint root
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint { op := .ensure, root? := some root.toString })

    let initial ← checkInitialWarningSync port root
    let broken ← checkBrokenSync port root initial
    let brokenResync ← checkUnchangedBrokenResync port root broken
    checkRecoveredSync port root brokenResync

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

end RunAtTest.Broker.SyncSummaryDeltaTest
