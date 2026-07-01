/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.Broker.SmokeUtil

set_option maxRecDepth 4096

open Lean

namespace BeamTest.Broker.SmokeTest

open BeamTest.Broker.TestUtil

private def syncVersion
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (path : String) : IO Nat := do
  let resp ← runClient endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some path
  }
  let result ← requireSyncFileResult s!"sync version for {path}" (← expectOk resp)
  pure result.version

private def updateVersion
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (path : String) : IO Nat := do
  let resp ← runClient endpoint {
    op := .updateFile
    root? := some root.toString
    path? := some path
  }
  let result ← requireUpdateFileResult s!"update version for {path}" (← expectOk resp)
  pure result.version

private def expectVersionMismatchData
    (label : String)
    (resp : Beam.Broker.Response)
    (expectedVersion acceptedVersion : Nat) : IO Unit := do
  let some err := resp.error?
    | throw <| IO.userError s!"{label}: expected error response, got {(toJson resp).compress}"
  let some data := err.data?
    | throw <| IO.userError s!"{label}: expected error.data, got {(toJson resp).compress}"
  let reason ← IO.ofExcept <| data.getObjValAs? String "reason"
  if reason != "documentVersionMismatch" then
    throw <| IO.userError s!"{label}: expected documentVersionMismatch data, got {data.compress}"
  let expected ← IO.ofExcept <| data.getObjValAs? Nat "expectedVersion"
  if expected != expectedVersion then
    throw <| IO.userError s!"{label}: expected expectedVersion={expectedVersion}, got {data.compress}"
  let accepted ← IO.ofExcept <| data.getObjValAs? Nat "acceptedVersion"
  if accepted != acceptedVersion then
    throw <| IO.userError s!"{label}: expected acceptedVersion={acceptedVersion}, got {data.compress}"
  let current ← IO.ofExcept <| data.getObjValAs? Nat "currentVersion"
  if current != acceptedVersion then
    throw <| IO.userError s!"{label}: expected currentVersion={acceptedVersion}, got {data.compress}"

private def runUpdateSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let dir := root / ".tmp" / s!"beam-update-smoke-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "UpdateSmoke.lean"
  IO.FS.writeFile path "def updateSmokeVal : Nat := 1\n"
  let relPath := Beam.pathRelativeToRootOrSelf root path
  let firstResp ← runClient endpoint {
    op := .updateFile
    root? := some root.toString
    path? := some relPath
  }
  let first ← requireUpdateFileResult "initial update_file" (← expectOk firstResp)
  if first.version != 1 || !first.changed then
    throw <| IO.userError s!"expected initial update_file version 1 changed=true, got {(toJson first).compress}"
  let unchangedResp ← runClient endpoint {
    op := .updateFile
    root? := some root.toString
    path? := some relPath
  }
  let unchanged ← requireUpdateFileResult "unchanged update_file" (← expectOk unchangedResp)
  if unchanged.version != first.version || unchanged.changed then
    throw <| IO.userError s!"expected unchanged update_file to preserve version and report changed=false, got {(toJson unchanged).compress}"
  let syncResp ← runClient endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some relPath
  }
  let syncRes ← requireSyncFileResult "sync after update_file" (← expectOk syncResp)
  if syncRes.version != first.version then
    throw <| IO.userError s!"expected sync_file after update_file to reuse version {first.version}, got {syncRes.version}"
  let runAtResp ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some relPath
    version? := some first.version
    line? := some 0
    character? := some 0
    text? := some "#check Nat"
  }
  let runAtRes ← expectOk runAtResp
  let .ok true := runAtRes.getObjValAs? Bool "success"
    | throw <| IO.userError s!"expected run_at with update_file version to succeed, got {runAtRes.compress}"

  IO.FS.writeFile path "def updateSmokeVal : Nat := 2\n"
  let changedResp ← runClient endpoint {
    op := .updateFile
    root? := some root.toString
    path? := some relPath
  }
  let changed ← requireUpdateFileResult "changed update_file" (← expectOk changedResp)
  if changed.version != first.version + 1 || !changed.changed then
    throw <| IO.userError s!"expected changed update_file to bump version and report changed=true, got {(toJson changed).compress}"
  let syncChangedResp ← runClient endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some relPath
  }
  let syncChanged ← requireSyncFileResult "sync after changed update_file" (← expectOk syncChangedResp)
  if syncChanged.version != changed.version then
    throw <| IO.userError s!"expected sync_file after changed update_file to reuse version {changed.version}, got {syncChanged.version}"
  let staleRunAtResp ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some relPath
    version? := some first.version
    line? := some 0
    character? := some 0
    text? := some "#check Nat"
  }
  expectErrCode staleRunAtResp "contentModified"
  expectVersionMismatchData "stale run_at" staleRunAtResp first.version changed.version

private def runSyncSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let syncRequestId := some "smoke-sync"
  let (syncResp, syncEvents) ← runClientWithProgress endpoint {
    op := .syncFile
    clientRequestId? := syncRequestId
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
  }
  let syncRes ← requireSyncFileResult "sync_file" (← expectOk syncResp)
  if syncRes.version != 1 then
    throw <| IO.userError s!"expected sync_file version 1, got {syncRes.version}"
  let syncSummary := syncRes.syncSummary
  if !syncSummary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected sync_file saveReady = true for clean module, got {(toJson syncSummary).compress}"
  if syncSummary.readiness.current.errorCount != 0 then
    throw <| IO.userError
      s!"expected sync_file readiness counts to be zero for clean module, got {(toJson syncSummary).compress}"
  let syncTop := ← requireFileProgress "sync_file" syncResp
  expectClientRequestId "sync_file response" syncResp.clientRequestId? syncRequestId
  if !syncTop.done then
    throw <| IO.userError s!"expected top-level sync_file fileProgress.done = true, got {(toJson syncTop).compress}"
  let some syncLast := syncEvents.back?
    | throw <| IO.userError "expected sync_file to stream fileProgress events"
  expectClientRequestId "sync_file progress" syncLast.clientRequestId? syncRequestId
  if !syncLast.progress.done then
    throw <| IO.userError s!"expected final streamed sync_file progress to be done, got {(toJson syncLast.progress).compress}"
  let syncRespAgain ← runClient endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
  }
  let syncResAgain ← requireSyncFileResult "unchanged sync_file" (← expectOk syncRespAgain)
  if syncResAgain.version != 1 then
    throw <| IO.userError s!"expected unchanged sync_file version 1, got {syncResAgain.version}"
  let syncTopAgain := ← requireFileProgress "unchanged sync_file" syncRespAgain
  if !syncTopAgain.done then
    throw <| IO.userError s!"expected unchanged sync_file fileProgress.done = true, got {(toJson syncTopAgain).compress}"
  let refreshRequestId := some "smoke-refresh"
  let (refreshResp, refreshEvents) ← runClientWithProgress endpoint {
    op := .refreshFile
    clientRequestId? := refreshRequestId
    root? := some root.toString
    path? := some "tests/scenario/docs/CommandA.lean"
  }
  let refreshRes ← requireSyncFileResult "refresh_file" (← expectOk refreshResp)
  if refreshRes.version != 1 then
    throw <| IO.userError s!"expected refresh_file to reopen version 1, got {refreshRes.version}"
  let refreshTop := ← requireFileProgress "refresh_file" refreshResp
  expectClientRequestId "refresh_file response" refreshResp.clientRequestId? refreshRequestId
  if !refreshTop.done then
    throw <| IO.userError s!"expected top-level refresh_file fileProgress.done = true, got {(toJson refreshTop).compress}"
  let some refreshLast := refreshEvents.back?
    | throw <| IO.userError "expected refresh_file to stream fileProgress events"
  expectClientRequestId "refresh_file progress" refreshLast.clientRequestId? refreshRequestId
  if !refreshLast.progress.done then
    throw <| IO.userError s!"expected final streamed refresh_file progress to be done, got {(toJson refreshLast.progress).compress}"

private def runErrorOnlySyncSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let errorPath ← writeStandaloneErrorFile root
  let errorRel := Beam.pathRelativeToRootOrSelf root errorPath
  let (errorResp, errorProgress, errorDiagnostics) ← runClientWithStream endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some errorPath.toString
  }
  let errorRes ← requireSyncFileResult "error-only sync_file" (← expectOk errorResp)
  if errorRes.version != 1 then
    throw <| IO.userError s!"expected error-only sync_file version 1, got {errorRes.version}"
  let errorSummary := errorRes.syncSummary
  if errorSummary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected error-only sync_file saveReady = false, got {(toJson errorSummary).compress}"
  if errorSummary.readiness.current.errorCount == 0 then
    throw <| IO.userError
      s!"expected error-only sync_file readiness errorCount > 0, got {(toJson errorSummary).compress}"
  if errorSummary.readiness.current.blockingDiagnostics.isEmpty &&
      errorSummary.readiness.current.blockingCommandMessages.isEmpty then
    throw <| IO.userError
      s!"expected error-only sync_file to include save-blocking evidence, got {(toJson errorSummary).compress}"
  unless errorSummary.readiness.current.blockingDiagnostics.all (·.saveBlocking) &&
      errorSummary.readiness.current.blockingCommandMessages.all (·.saveBlocking) do
    throw <| IO.userError
      s!"expected error-only sync_file blocking evidence to be flagged saveBlocking, got {(toJson errorSummary).compress}"
  if errorSummary.readiness.current.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"expected error-only sync_file saveReadyReason = documentErrors, got {(toJson errorSummary).compress}"
  let some errorLast := errorProgress.back?
    | throw <| IO.userError "expected error-only sync_file to stream fileProgress events"
  if !errorLast.done then
    throw <| IO.userError s!"expected error-only sync_file progress to finish, got {(toJson errorLast).compress}"
  if errorDiagnostics.isEmpty then
    throw <| IO.userError "expected error-only sync_file to stream error diagnostics"
  unless errorDiagnostics.all (fun diagnostic => diagnostic.severity? == some .error) do
    throw <| IO.userError s!"expected error-only sync_file to stream only errors by default, got {(toJson errorDiagnostics).compress}"
  unless errorDiagnostics.all (fun diagnostic => diagnostic.path == errorRel) do
    throw <| IO.userError s!"expected error-only sync_file paths to match {errorRel}, got {(toJson errorDiagnostics).compress}"

private def runInteractiveOnlyDiagnosticSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let path := "tests/scenario/docs/InteractiveOnlyDiagnostic.lean"
  let (resp, progress, diagnostics) ← runClientWithStream endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some path
  }
  let res ← requireSyncFileResult "interactive-only diagnostic sync_file" (← expectOk resp)
  let summary := res.syncSummary
  if summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected interactive-only diagnostic sync_file saveReady = false, got {(toJson summary).compress}"
  if summary.readiness.current.errorCount == 0 then
    throw <| IO.userError
      s!"expected interactive-only diagnostic counts to report Lean errors only, got {(toJson res).compress}"
  if summary.readiness.current.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"expected interactive-only diagnostic saveReadyReason = documentErrors, got {(toJson summary).compress}"
  if summary.currentVersion != res.version then
    throw <| IO.userError
      s!"expected interactive-only diagnostic syncSummary version to match result version, got {(toJson summary).compress}"
  if summary.diagnostics.current.error == 0 || summary.diagnostics.current.total == 0 then
    throw <| IO.userError
      s!"expected interactive-only diagnostic syncSummary to count the error-severity diagnostic, got {(toJson summary).compress}"
  -- Regression for #99: current diagnostic errors must not coexist with saveReady=true.
  if summary.diagnostics.current.error > 0 && summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected interactive-only diagnostic errors to make syncSummary saveReady=false, got {(toJson summary).compress}"
  if summary.readiness.current.errorCount == 0 then
    throw <| IO.userError
      s!"expected interactive-only diagnostic syncSummary readiness to be blocked, got {(toJson summary).compress}"
  if summary.readiness.current.blockingDiagnostics.isEmpty ||
      summary.readiness.current.blockingCommandMessages.isEmpty then
    throw <| IO.userError
      s!"expected interactive-only diagnostic syncSummary to include Lean-side blocking evidence, got {(toJson summary).compress}"
  let some lastProgress := progress.back?
    | throw <| IO.userError "expected interactive-only diagnostic sync_file to stream fileProgress"
  if !lastProgress.done then
    throw <| IO.userError
      s!"expected interactive-only diagnostic sync_file progress to finish, got {(toJson lastProgress).compress}"
  unless diagnostics.any (fun diagnostic =>
      diagnostic.path == path && diagnostic.severity? == some .error &&
        diagnostic.message.contains "interactive-only diagnostic") do
    throw <| IO.userError
      s!"expected interactive-only diagnostic sync_file to stream the fixture error, got {(toJson diagnostics).compress}"

private def runTodoThenSyncDiagnosticSummarySmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let path := "tests/scenario/docs/InteractiveOnlyDiagnostic.lean"
  let version ← syncVersion endpoint root path
  let todoResp ← runClient endpoint {
    op := .todo
    root? := some root.toString
    path? := some path
    version? := some version
    line? := some 0
    character? := some 0
    endLine? := some 22
    endCharacter? := some 0
    kinds? := some #[.diagnostic]
    suggest? := some .none
  }
  let todoResult : Beam.LSP.Todo.TodoResult ← IO.ofExcept <| fromJson? (← expectOk todoResp)
  unless todoResult.items.any (fun item =>
      item.kind == .diagnostic &&
        item.severity? == some .error &&
        item.message?.map (·.contains "interactive-only diagnostic") == some true) do
    throw <| IO.userError
      s!"expected todo to observe interactive-only error diagnostic, got {(toJson todoResult).compress}"

  let syncResp ← runClient endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some path
  }
  let syncRes ← requireSyncFileResult "todo-warmed diagnostic sync_file" (← expectOk syncResp)
  let summary := syncRes.syncSummary
  if summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected todo-warmed diagnostic sync_file saveReady = false, got {(toJson summary).compress}"
  if summary.diagnostics.current.error == 0 || summary.diagnostics.current.total == 0 then
    throw <| IO.userError
      s!"expected todo-warmed diagnostic syncSummary to retain current error counts, got {(toJson summary).compress}"
  if summary.readiness.current.errorCount == 0 then
    throw <| IO.userError
      s!"expected todo-warmed diagnostic syncSummary readiness to stay blocked, got {(toJson summary).compress}"
  discard <| expectOk <| ← runClient endpoint {
    op := .close
    root? := some root.toString
    path? := some path
  }

private def runReportedOnlyDiagnosticSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let path := "tests/scenario/docs/ReportedOnlyError.lean"
  let (resp, progress, diagnostics) ← runClientWithStream endpoint {
    op := .syncFile
    root? := some root.toString
    path? := some path
  }
  let res ← requireSyncFileResult "reported-only diagnostic sync_file" (← expectOk resp)
  let summary := res.syncSummary
  if !summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected reported-only diagnostic sync_file saveReady = true, got {(toJson summary).compress}"
  if summary.readiness.current.errorCount != 0 then
    throw <| IO.userError
      s!"expected reported-only diagnostic counts to be zero, got {(toJson summary).compress}"
  if summary.readiness.current.saveReadyReason != "ok" then
    throw <| IO.userError
      s!"expected reported-only diagnostic saveReadyReason = ok, got {(toJson summary).compress}"
  if summary.readiness.current.errorCount != 0 || !summary.readiness.current.saveReady then
    throw <| IO.userError
      s!"expected reported-only diagnostic syncSummary readiness to stay clean, got {(toJson summary).compress}"
  unless summary.readiness.current.blockingDiagnostics.isEmpty &&
      summary.readiness.current.blockingCommandMessages.isEmpty do
    throw <| IO.userError
      s!"expected reported-only diagnostic syncSummary to omit blocking evidence, got {(toJson summary).compress}"
  let some lastProgress := progress.back?
    | throw <| IO.userError "expected reported-only diagnostic sync_file to stream fileProgress"
  if !lastProgress.done then
    throw <| IO.userError
      s!"expected reported-only diagnostic sync_file progress to finish, got {(toJson lastProgress).compress}"
  unless diagnostics.isEmpty do
    throw <| IO.userError
      s!"expected reported-only diagnostic sync_file to stream no diagnostics, got {(toJson diagnostics).compress}"

private def runPartialProgressSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let partialRequestId := some "smoke-partial"
  let path := "tests/scenario/docs/PartialProgress.lean"
  let version ← syncVersion endpoint root path
  let (partialResp, partialEvents) ← runClientWithProgress endpoint {
    op := .runAt
    clientRequestId? := partialRequestId
    root? := some root.toString
    path? := some path
    version? := some version
    line? := some 7
    character? := some 2
    text? := some "#check partialProgressAnchor"
  }
  let partialRes ← expectOk partialResp
  let .ok true := partialRes.getObjValAs? Bool "success" | throw <| IO.userError "partial run_at did not succeed"
  let partialProgress := ← requireFileProgress "partial run_at" partialResp
  expectClientRequestId "partial run_at response" partialResp.clientRequestId? partialRequestId
  if !partialProgress.done then
    throw <| IO.userError s!"expected versioned run_at fileProgress.done = true after sync, got {(toJson partialProgress).compress}"
  if let some partialLast := partialEvents.back? then
    expectClientRequestId "partial run_at progress" partialLast.clientRequestId? partialRequestId
    if !partialLast.progress.done then
      throw <| IO.userError s!"expected final streamed versioned run_at progress to be complete, got {(toJson partialLast.progress).compress}"

private def runConcurrentSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let concurrentSyncId := some "concurrent-sync"
  let concurrentHoverId := some "concurrent-hover"
  let slowSyncPath ← writeSlowSyncFile root
  let hoverPath := "tests/scenario/docs/CommandA.lean"
  let hoverVersion ← updateVersion endpoint root hoverPath
  let syncTask ← IO.asTask (prio := Task.Priority.dedicated) <| runClientWithProgress endpoint {
    op := .syncFile
    clientRequestId? := concurrentSyncId
    root? := some root.toString
    path? := some slowSyncPath.toString
  }
  IO.sleep 200
  let hoverStartedAt ← IO.monoNanosNow
  let (hoverResp, hoverEvents) ← runClientWithProgress endpoint {
    op := .hover
    clientRequestId? := concurrentHoverId
    root? := some root.toString
    path? := some hoverPath
    version? := some hoverVersion
    line? := some 0
    character? := some 4
  }
  let _hoverLatencyMs := ((← IO.monoNanosNow) - hoverStartedAt) / 1000000
  let hoverPayload ← expectOk hoverResp
  expectClientRequestId "concurrent hover response" hoverResp.clientRequestId? concurrentHoverId
  expectProgressIds "concurrent hover progress" hoverEvents concurrentHoverId
  let hoverContents ← IO.ofExcept <| hoverPayload.getObjVal? "contents"
  let hoverValue ← IO.ofExcept <| hoverContents.getObjValAs? String "value"
  expectStringContains "concurrent hover markdown" hoverValue "answerA : Nat"
  let (concurrentSyncResp, concurrentSyncEvents) ← awaitTask "concurrent sync_file" syncTask
  let concurrentSyncTop := ← requireFileProgress "concurrent sync_file" concurrentSyncResp
  expectClientRequestId "concurrent sync_file response" concurrentSyncResp.clientRequestId? concurrentSyncId
  expectProgressIds "concurrent sync_file progress" concurrentSyncEvents concurrentSyncId
  if !concurrentSyncTop.done then
    throw <| IO.userError
      s!"expected concurrent sync_file fileProgress.done = true, got {(toJson concurrentSyncTop).compress}"

private def runRequestAndGoalsSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let commandPath := "tests/scenario/docs/CommandA.lean"
  let commandVersion ← updateVersion endpoint root commandPath
  let proofPath := "tests/scenario/docs/SimpleProof.lean"
  let proofVersion ← updateVersion endpoint root proofPath
  let cmdResp ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some commandPath
    version? := some commandVersion
    line? := some 0
    character? := some 2
    text? := some "#check answerA"
  }
  let cmdRes ← expectOk cmdResp
  let .ok true := cmdRes.getObjValAs? Bool "success" | throw <| IO.userError "run_at did not succeed"

  let hoverResp ← runClient endpoint {
    op := .hover
    root? := some root.toString
    path? := some commandPath
    version? := some commandVersion
    line? := some 0
    character? := some 4
  }
  let hover ← expectOk hoverResp
  discard <| requireFileProgress "hover" hoverResp
  let hoverContents ← IO.ofExcept <| hover.getObjVal? "contents"
  let hoverValue ← IO.ofExcept <| hoverContents.getObjValAs? String "value"
  expectStringContains "hover markdown" hoverValue "answerA : Nat"

  let definitionResp ← runClient endpoint {
    op := .definition
    root? := some root.toString
    path? := some commandPath
    version? := some commandVersion
    line? := some 0
    character? := some 4
  }
  let definition ← expectOk definitionResp
  discard <| requireFileProgress "definition" definitionResp
  expectStringContains "definition result" definition.compress "CommandA.lean"

  let referencesResp ← runClient endpoint {
    op := .references
    root? := some root.toString
    path? := some commandPath
    version? := some commandVersion
    line? := some 0
    character? := some 4
    includeDeclaration? := some true
  }
  let references ← expectOk referencesResp
  discard <| requireFileProgress "references" referencesResp
  expectStringContains "references result" references.compress "CommandA.lean"

  let documentSymbolsResp ← runClient endpoint {
    op := .documentSymbols
    root? := some root.toString
    path? := some commandPath
    version? := some commandVersion
  }
  let documentSymbols ← expectOk documentSymbolsResp
  discard <| requireFileProgress "document symbols" documentSymbolsResp
  let .arr documentSymbols := documentSymbols
    | throw <| IO.userError s!"expected document_symbols result array, got {documentSymbols.compress}"
  unless documentSymbols.any (fun sym =>
      (sym.getObjValAs? String "name").toOption == some "answerA") do
    throw <| IO.userError
      s!"expected document_symbols to include answerA, got {(Json.arr documentSymbols).compress}"

  let workspaceSymbolsResp ← runClient endpoint {
    op := .workspaceSymbols
    root? := some root.toString
    query? := some "runAtMethod"
  }
  let workspaceSymbols ← expectOk workspaceSymbolsResp
  match workspaceSymbols with
  | .arr _ => pure ()
  | _ => throw <| IO.userError s!"expected workspace_symbols result array, got {workspaceSymbols.compress}"

  let goalsPrevResp ← runClient endpoint {
    op := .goals
    root? := some root.toString
    path? := some proofPath
    version? := some proofVersion
    line? := some 1
    character? := some 2
    mode? := some .before
  }
  let goalsPrev ← expectOk goalsPrevResp
  discard <| requireFileProgress "goals prev" goalsPrevResp
  let prevGoals ← IO.ofExcept <| goalsPrev.getObjVal? "goals"
  let .arr prevGoals := prevGoals
    | throw <| IO.userError s!"expected goals prev result to be an array, got {prevGoals.compress}"
  if prevGoals.size != 1 then
    throw <| IO.userError s!"expected one previous goal, got {(Json.arr prevGoals).compress}"
  let prevTarget ← IO.ofExcept <| prevGoals[0]!.getObjValAs? String "target"
  expectStringContains "goals prev target" prevTarget "True"

  let goalsAfterResp ← runClient endpoint {
    op := .goals
    root? := some root.toString
    path? := some proofPath
    version? := some proofVersion
    line? := some 1
    character? := some 2
    mode? := some .after
  }
  let goalsAfter ← expectOk goalsAfterResp
  discard <| requireFileProgress "goals after" goalsAfterResp
  let afterGoals := ← IO.ofExcept <| goalsAfter.getObjVal? "goals"
  if afterGoals != Json.arr #[] then
    throw <| IO.userError s!"expected no goals after trivial, got {afterGoals.compress}"

private def runCancelSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let slowRequestId := some "cancel-slow"
  let slowPath := "tests/scenario/docs/SlowPoll.lean"
  let slowVersion ← updateVersion endpoint root slowPath
  let slowTask ← IO.asTask (prio := Task.Priority.dedicated) <| runClientWithProgress endpoint {
    op := .runAt
    clientRequestId? := slowRequestId
    root? := some root.toString
    path? := some slowPath
    version? := some slowVersion
    line? := some 25
    character? := some 2
    text? := some "poll_sleep_cmd"
  }
  IO.sleep 200
  let cancelResp ← runClient endpoint {
    op := .cancel
    root? := some root.toString
    cancelRequestId? := slowRequestId
  }
  let cancelPayload ← expectOk cancelResp
  let .ok true := cancelPayload.getObjValAs? Bool "cancelled"
    | throw <| IO.userError s!"expected cancel response to report cancelled=true, got {cancelPayload.compress}"
  let (slowResp, slowEvents) ← awaitTask "cancel slow run_at" slowTask
  expectErrCode slowResp "requestCancelled"
  expectClientRequestId "cancelled run_at response" slowResp.clientRequestId? slowRequestId
  expectProgressIds "cancelled run_at progress" slowEvents slowRequestId

  let commandPath := "tests/scenario/docs/CommandA.lean"
  let commandVersion ← updateVersion endpoint root commandPath
  let postCancelHoverResp ← runClient endpoint {
    op := .hover
    root? := some root.toString
    path? := some commandPath
    version? := some commandVersion
    line? := some 0
    character? := some 4
  }
  let postCancelHover ← expectOk postCancelHoverResp
  let postCancelHoverContents ← IO.ofExcept <| postCancelHover.getObjVal? "contents"
  let postCancelHoverValue ← IO.ofExcept <| postCancelHoverContents.getObjValAs? String "value"
  expectStringContains "post-cancel hover markdown" postCancelHoverValue "answerA : Nat"

private def runWorkerExitSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let branchPath := "tests/scenario/docs/BranchProof.lean"
  let branchVersion ← updateVersion endpoint root branchPath
  let handleSeed ← expectOk <| ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some branchPath
    version? := some branchVersion
    line? := some 0
    character? := some 27
    text? := some "constructor"
    storeHandle? := some true
  }
  let handleJson ← IO.ofExcept <| handleSeed.getObjVal? "handle"
  let staleHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? handleJson

  let workerExitRequestId := some "worker-exit-slow"
  let slowPath := "tests/scenario/docs/SlowPoll.lean"
  let slowVersion ← updateVersion endpoint root slowPath
  let slowTask ← IO.asTask (prio := Task.Priority.dedicated) <| runClientWithProgress endpoint {
    op := .runAt
    clientRequestId? := workerExitRequestId
    root? := some root.toString
    path? := some slowPath
    version? := some slowVersion
    line? := some 25
    character? := some 2
    text? := some "poll_sleep_cmd"
  }
  IO.sleep 200
  killLeanServerForEndpoint endpoint root
  let (slowResp, slowEvents) ← awaitTask "worker-exit slow run_at" slowTask
  expectErrCode slowResp "workerExited"
  expectClientRequestId "worker-exit run_at response" slowResp.clientRequestId? workerExitRequestId
  expectProgressIds "worker-exit run_at progress" slowEvents workerExitRequestId

  let commandPath := "tests/scenario/docs/CommandA.lean"
  let commandVersion ← updateVersion endpoint root commandPath
  let restartHoverResp ← runClient endpoint {
    op := .hover
    root? := some root.toString
    path? := some commandPath
    version? := some commandVersion
    line? := some 0
    character? := some 4
  }
  let restartHover ← expectOk restartHoverResp
  let restartHoverContents ← IO.ofExcept <| restartHover.getObjVal? "contents"
  let restartHoverValue ← IO.ofExcept <| restartHoverContents.getObjValAs? String "value"
  expectStringContains "post-restart hover markdown" restartHoverValue "answerA : Nat"

  let staleAfterRestart ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some staleHandle
    text? := some "exact trivial"
  }
  expectErrCode staleAfterRestart "contentModified"

private def runHandleSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let branchPath := "tests/scenario/docs/BranchProof.lean"
  let branchVersion ← updateVersion endpoint root branchPath
  let proofRes ← expectOk <| ← runClient endpoint {
    op := .runAt
    root? := some root.toString
    path? := some branchPath
    version? := some branchVersion
    line? := some 0
    character? := some 27
    text? := some "constructor"
    storeHandle? := some true
  }
  let handleJson ← IO.ofExcept <| proofRes.getObjVal? "handle"
  let handle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? handleJson
  let proofNext ← expectOk <| ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some handle
    text? := some "exact trivial"
    storeHandle? := some true
  }
  let nextHandleJson ← IO.ofExcept <| proofNext.getObjVal? "handle"
  let nextHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? nextHandleJson
  let proofDone ← expectOk <| ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some nextHandle
    text? := some "exact trivial"
  }
  let goals ← IO.ofExcept <| proofDone.getObjVal? "proofState"
  let goals := (← IO.ofExcept <| goals.getObjVal? "goals")
  if goals != Json.arr #[] then
    throw <| IO.userError s!"expected no goals, got {goals.compress}"

  discard <| expectOk <| ← runClient endpoint {
    op := .release
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some handle
  }
  let stale ← runClient endpoint {
    op := .runWith
    root? := some root.toString
    path? := some "tests/scenario/docs/BranchProof.lean"
    handle? := some handle
    text? := some "exact trivial"
  }
  expectErrCode stale "invalidParams"
private def runSaveAndStatsSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let saveResp ← runClient endpoint {
    op := .saveOlean
    root? := some root.toString
    path? := some "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  }
  let savePayload ← expectOk saveResp
  let saveVersion ← IO.ofExcept <| savePayload.getObjValAs? Nat "version"
  if saveVersion != 1 then
    throw <| IO.userError s!"expected save_olean version = 1, got {saveVersion}"
  let saveHash ← IO.ofExcept <| savePayload.getObjValAs? String "sourceHash"
  if saveHash.isEmpty then
    throw <| IO.userError "expected save_olean sourceHash to be present"
  let saveProgress := ← requireFileProgress "save_olean" saveResp
  if !saveProgress.done then
    throw <| IO.userError s!"expected save_olean fileProgress.done = true, got {(toJson saveProgress).compress}"

  let stats ← expectOk <| ← runClient endpoint { op := .stats }
  expectOpCountAtLeast stats "lean" "sync_file" 1
  expectOpCountAtLeast stats "lean" "refresh_file" 1
  expectOpCountAtLeast stats "lean" "update_file" 1
  expectOpCountAtLeast stats "lean" "run_at" 3
  expectOpCountAtLeast stats "lean" "hover" 4
  expectOpCountAtLeast stats "lean" "goals" 2
  expectOpCountAtLeast stats "lean" "run_with" 3
  expectOpCountAtLeast stats "lean" "release" 1
  expectOpCountAtLeast stats "lean" "save_olean" 1
  expectBackendMetricAtLeast stats "lean" "cancelledCount" 1
  expectBackendMetricAtLeast stats "lean" "workerExitedCount" 1
  expectBackendMetricAtLeast stats "lean" "sessionRestarts" 1
  expectOpMetricAtLeast stats "lean" "run_at" "cancelledCount" 1
  expectOpMetricAtLeast stats "lean" "run_at" "workerExitedCount" 1

def smokeMain : IO Unit := do
  let endpoint ← freshTcpEndpoint
  let root ← repoRoot
  let otherRoot ← IO.FS.realPath <| root / "tests" / "save_olean_project"
  let broker ← spawnLeanBrokerWithPlugin endpoint root (← pluginPath) (← leanCmd)
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint { op := .ensure, root? := some root.toString })
    let rootMismatch ← runClient endpoint { op := .ensure, root? := some otherRoot.toString }
    expectErrCode rootMismatch "invalidParams"
    discard <| expectOk (← runClient endpoint { op := .resetStats })
    runUpdateSmoke endpoint root
    runSyncSmoke endpoint root
    runErrorOnlySyncSmoke endpoint root
    runTodoThenSyncDiagnosticSummarySmoke endpoint root
    runInteractiveOnlyDiagnosticSmoke endpoint root
    runReportedOnlyDiagnosticSmoke endpoint root
    runPartialProgressSmoke endpoint root
    runConcurrentSmoke endpoint root
    runRequestAndGoalsSmoke endpoint root
    runCancelSmoke endpoint root
    runWorkerExitSmoke endpoint root
    runHandleSmoke endpoint root
    runSaveAndStatsSmoke endpoint root

    let shutdownResp ← runClient endpoint { op := .shutdown }
    discard <| expectOk shutdownResp
  finally
    try
      broker.kill
    catch _ =>
      pure ()

end BeamTest.Broker.SmokeTest
