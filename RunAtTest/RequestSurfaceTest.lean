/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import RunAtTest.Scenario
import RunAt.Internal.DirectImports
import RunAt.Internal.SaveSupport
import RunAtTest.TodoFixture

open Lean
open RunAtTest.Scenario

namespace RunAtTest.RequestSurfaceTest

private def expectFileExists (label : String) (path : System.FilePath) : ScenarioM Unit := do
  unless ← path.pathExists do
    throw <| IO.userError s!"{label}: expected file {path} to exist"

private def requireSingleGoalTarget (label expectedNeedle : String) (state : RunAt.ProofState) :
    ScenarioM Unit := do
  let some goal := state.goals[0]?
    | throw <| IO.userError s!"{label}: expected one goal"
  unless goal.target.contains expectedNeedle do
    throw <| IO.userError s!"{label}: expected target to contain '{expectedNeedle}', got '{goal.target}'"

private def requireTodoKind (label : String) (kind : RunAt.TodoKind) (result : RunAt.TodoResult) :
    ScenarioM RunAt.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind)
    | throw <| IO.userError s!"{label}: expected todo kind {kind.key}, got {(toJson result).compress}"
  pure item

private def requireNoTodoKind (label : String) (kind : RunAt.TodoKind) (result : RunAt.TodoResult) :
    ScenarioM Unit := do
  if result.items.any (fun item => item.kind == kind) then
    throw <| IO.userError s!"{label}: unexpected todo kind {kind.key}: {(toJson result).compress}"

private def countTodoKind (kind : RunAt.TodoKind) (result : RunAt.TodoResult) : Nat :=
  result.items.foldl (init := 0) fun count item =>
    if item.kind == kind then count + 1 else count

private def requireRangeEq (label : String) (expected actual : Lean.Lsp.Range) : ScenarioM Unit := do
  unless actual == expected do
    throw <| IO.userError s!"{label}: expected range {repr expected}, got {repr actual}"

private def requireRunAtSuccess
    (label : String)
    (doc : DocHandle)
    (position : Lean.Lsp.Position)
    (text : String) : ScenarioM RunAt.Result := do
  let req ← sendRunAt doc {
    line := position.line
    character := position.character
    text
  }
  let result : RunAt.Result ← awaitResponseAs req
  unless result.success do
    throw <| IO.userError s!"{label}: expected runAt success, got {(toJson result).compress}"
  pure result

private def requireRunAtSolvesProof
    (label : String)
    (doc : DocHandle)
    (position : Lean.Lsp.Position)
    (text : String) : ScenarioM Unit := do
  let result ← requireRunAtSuccess label doc position text
  let some proofState := result.proofState?
    | throw <| IO.userError s!"{label}: expected proofState, got {(toJson result).compress}"
  unless proofState.goals.isEmpty do
    throw <| IO.userError s!"{label}: expected solved proof state, got {(toJson proofState).compress}"

private def mkTmpDir (stem : String) : ScenarioM System.FilePath := do
  let dir := System.FilePath.mk s!"/tmp/{stem}-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  pure dir

private def checkGoalsRequests : ScenarioM Unit := do
  let doc ← openDoc "tests/save_olean_project/GoalSmoke.lean"

  let goalsPrevReq ← sendGoals doc { line := 1, character := 2, useAfter := false }
  let goalsPrev : RunAt.ProofState ← awaitResponseAs goalsPrevReq
  if goalsPrev.goals.size != 1 then
    throw <| IO.userError s!"goals prev: expected one goal, got {goalsPrev.goals.size}"
  requireSingleGoalTarget "goals prev" "True" goalsPrev

  let goalsAfterReq ← sendGoals doc { line := 1, character := 2, useAfter := true }
  let goalsAfter : RunAt.ProofState ← awaitResponseAs goalsAfterReq
  if goalsAfter.goals.size != 0 then
    throw <| IO.userError s!"goals after: expected solved proof state, got {goalsAfter.goals.size} goals"

  closeDoc doc

private def checkTodoRequest : ScenarioM Unit := do
  let doc ← openDoc RunAtTest.TodoFixture.repoPath
  syncDoc doc

  let allReq ← sendTodo doc {
    startLine := RunAtTest.TodoFixture.startLine
    startCharacter := RunAtTest.TodoFixture.startCharacter
    endLine := RunAtTest.TodoFixture.endLine
    endCharacter := RunAtTest.TodoFixture.endCharacter
    suggest? := some .basic
  }
  let allTodos : RunAt.TodoResult ← awaitResponseAs allReq
  let sorryItem ← requireTodoKind "todo all" .sorry allTodos
  if countTodoKind .sorry allTodos != 1 then
    throw <| IO.userError s!"todo all: expected one actionable sorry, got {(toJson allTodos).compress}"
  if sorryItem.range.start != RunAtTest.TodoFixture.sorryPosition then
    throw <| IO.userError
      s!"todo all: expected sorry token range at {RunAtTest.TodoFixture.sorryPosition}, got {(toJson sorryItem).compress}"
  let holeItem ← requireTodoKind "todo all" .hole allTodos
  if holeItem.runAtText?.isSome then
    throw <| IO.userError s!"todo all: expected hole to omit runAtText, got {(toJson holeItem).compress}"
  let incomplete ← requireTodoKind "todo all" .incompleteProof allTodos
  if countTodoKind .incompleteProof allTodos != 1 then
    throw <| IO.userError s!"todo all: expected one incomplete proof item, got {(toJson allTodos).compress}"
  if incomplete.runAtText? != some "exact ?_" then
    throw <| IO.userError s!"todo all: expected incomplete proof runAtText, got {(toJson incomplete).compress}"
  let some proofState := incomplete.proofState?
    | throw <| IO.userError s!"todo all: expected incomplete proofState, got {(toJson incomplete).compress}"
  requireSingleGoalTarget "todo incomplete proof" "True" proofState

  let pointIncompleteReq ← sendTodo doc {
    startLine := incomplete.runAtPosition.line
    startCharacter := incomplete.runAtPosition.character
    endLine := incomplete.runAtPosition.line
    endCharacter := incomplete.runAtPosition.character
    kinds? := some #[.incompleteProof]
    suggest? := some .none
  }
  let pointIncompleteTodos : RunAt.TodoResult ← awaitResponseAs pointIncompleteReq
  let pointIncomplete ← requireTodoKind "todo point incomplete proof" .incompleteProof pointIncompleteTodos
  if countTodoKind .incompleteProof pointIncompleteTodos != 1 then
    throw <| IO.userError
      s!"todo point incomplete proof: expected one item, got {(toJson pointIncompleteTodos).compress}"
  if pointIncomplete.runAtText?.isSome then
    throw <| IO.userError
      s!"todo point incomplete proof: expected suggest=none to omit runAtText, got {(toJson pointIncomplete).compress}"
  let some pointProofState := pointIncomplete.proofState?
    | throw <| IO.userError s!"todo point incomplete proof: expected proofState, got {(toJson pointIncomplete).compress}"
  requireSingleGoalTarget "todo point incomplete proof" "True" pointProofState

  let reversedReq ← sendTodo doc {
    startLine := RunAtTest.TodoFixture.endLine
    startCharacter := RunAtTest.TodoFixture.endCharacter
    endLine := RunAtTest.TodoFixture.startLine
    endCharacter := RunAtTest.TodoFixture.startCharacter
  }
  let reversedOutcome ← awaitReq reversedReq
  if reversedOutcome.errorCode? != some "invalidParams" then
    throw <| IO.userError
      s!"todo reversed range: expected invalidParams, got {reversedOutcome.errorCode?.getD "normal response"}: {reversedOutcome.errorMessage}"

  let skippedSorryReq ← sendTodo doc {
    startLine := RunAtTest.TodoFixture.startLine
    startCharacter := RunAtTest.TodoFixture.startCharacter
    endLine := RunAtTest.TodoFixture.skippedSorryEndLine
    endCharacter := RunAtTest.TodoFixture.endCharacter
    kinds? := some #[.sorry]
  }
  let skippedSorryTodos : RunAt.TodoResult ← awaitResponseAs skippedSorryReq
  if !skippedSorryTodos.items.isEmpty then
    throw <| IO.userError s!"todo skipped sorry text: expected no actionable sorry, got {(toJson skippedSorryTodos).compress}"

  let sorryReq ← sendTodo doc {
    startLine := RunAtTest.TodoFixture.startLine
    startCharacter := RunAtTest.TodoFixture.startCharacter
    endLine := RunAtTest.TodoFixture.endLine
    endCharacter := RunAtTest.TodoFixture.endCharacter
    kinds? := some #[.sorry]
    suggest? := some .none
  }
  let sorryTodos : RunAt.TodoResult ← awaitResponseAs sorryReq
  discard <| requireTodoKind "todo sorry filter" .sorry sorryTodos
  if countTodoKind .sorry sorryTodos != 1 then
    throw <| IO.userError s!"todo sorry filter: expected one actionable sorry, got {(toJson sorryTodos).compress}"
  requireNoTodoKind "todo sorry filter" .hole sorryTodos
  requireNoTodoKind "todo sorry filter" .incompleteProof sorryTodos

  requireRunAtSolvesProof "todo/runAt sorry composition" doc sorryItem.runAtPosition "exact trivial"
  requireRunAtSolvesProof "todo/runAt incomplete composition" doc incomplete.runAtPosition "exact trivial"

  let starterReq ← sendRunAt doc {
    line := incomplete.runAtPosition.line
    character := incomplete.runAtPosition.character
    text := incomplete.runAtText?.getD "exact ?_"
  }
  let starterOutcome ← awaitReq starterReq
  if starterOutcome.result?.isNone then
    throw <| IO.userError
      s!"todo/runAt starter composition: expected normal runAt result, got {starterOutcome.errorCode?.getD "unknown"}: {starterOutcome.errorMessage}"

  closeDoc doc

private def checkTodoCodeActions : ScenarioM Unit := do
  let doc ← openDoc RunAtTest.TodoFixture.codeActionRepoPath
  syncDoc doc

  let codeActionReq ← sendTodo doc {
    startLine := RunAtTest.TodoFixture.codeActionLine
    startCharacter := RunAtTest.TodoFixture.codeActionStartCharacter
    endLine := RunAtTest.TodoFixture.codeActionLine
    endCharacter := RunAtTest.TodoFixture.codeActionEndCharacter
    kinds? := some #[.codeAction]
  }
  let codeActionTodos : RunAt.TodoResult ← awaitResponseAs codeActionReq
  let actionItem ← requireTodoKind "todo code action fixture" .codeAction codeActionTodos
  if countTodoKind .codeAction codeActionTodos != 1 then
    throw <| IO.userError
      s!"todo code action fixture: expected one code action, got {(toJson codeActionTodos).compress}"
  requireRangeEq "todo code action fixture"
    RunAtTest.TodoFixture.codeActionRange actionItem.range
  if actionItem.runAtPosition != RunAtTest.TodoFixture.codeActionRange.start then
    throw <| IO.userError
      s!"todo code action fixture: expected runAtPosition to track the code-action range start, got {(toJson actionItem).compress}"
  if actionItem.message? != some "Replace fixture hole with zero" then
    throw <| IO.userError
      s!"todo code action fixture: expected code action title message, got {(toJson actionItem).compress}"
  let some action := actionItem.codeAction?
    | throw <| IO.userError s!"todo code action fixture: expected embedded codeAction payload, got {(toJson actionItem).compress}"
  if action.title != "Replace fixture hole with zero" then
    throw <| IO.userError s!"todo code action fixture: unexpected code action title {action.title}"
  if action.kind? != some "quickfix" then
    throw <| IO.userError s!"todo code action fixture: expected quickfix action, got {(toJson action).compress}"
  if action.edit?.isNone then
    throw <| IO.userError s!"todo code action fixture: expected edit payload, got {(toJson action).compress}"
  if action.data?.isNone then
    throw <| IO.userError s!"todo code action fixture: expected resolve data, got {(toJson action).compress}"

  closeDoc doc

private def checkDirectImportsAndSave : ScenarioM Unit := do
  let doc ← openDoc "RunAtTest/Deps/DepA.lean"

  let importsReq ← sendDirectImports doc
  let imports : RunAt.Internal.DirectImportsResult ← awaitResponseAs importsReq
  if imports.version != 1 then
    throw <| IO.userError s!"directImports: expected version 1, got {imports.version}"
  if imports.imports != #["RunAtTest.Deps.DepB"] then
    throw <| IO.userError s!"directImports: unexpected imports {(toJson imports.imports).compress}"

  let readinessReq ← sendSaveReadiness doc
  let readiness : RunAt.Internal.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError s!"saveReadiness: expected saveReady = true, got {(toJson readiness).compress}"
  if readiness.saveReadyReason != "ok" then
    throw <| IO.userError s!"saveReadiness: expected reason = ok, got {readiness.saveReadyReason}"

  let outDir ← mkTmpDir "runat-request-surface"
  let saveReq ← sendSaveArtifacts doc {
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }
  let saved : RunAt.Internal.SaveArtifactsResult ← awaitResponseAs saveReq
  if !saved.written then
    throw <| IO.userError "saveArtifacts: expected written = true"
  if saved.version != 1 then
    throw <| IO.userError s!"saveArtifacts: expected version 1, got {saved.version}"
  expectFileExists "saveArtifacts olean" (outDir / "DepA.olean")
  expectFileExists "saveArtifacts ilean" (outDir / "DepA.ilean")
  expectFileExists "saveArtifacts c" (outDir / "DepA.c")

  changeDoc doc {
    line := 8
    character := 18
    delete := "depB"
    insert := "\"oops\""
  }
  syncDoc doc

  let brokenReq ← sendSaveReadiness doc
  let broken : RunAt.Internal.SaveReadinessResult ← awaitResponseAs brokenReq
  if broken.saveReady then
    throw <| IO.userError s!"broken saveReadiness: expected saveReady = false, got {(toJson broken).compress}"
  if broken.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"broken saveReadiness: expected reason = documentErrors, got {broken.saveReadyReason}"
  if broken.diagnosticErrorCount == 0 then
    throw <| IO.userError s!"broken saveReadiness: expected diagnosticErrorCount > 0, got {(toJson broken).compress}"

  closeDoc doc

def main : IO Unit := RunAtTest.Scenario.run do
  checkGoalsRequests
  checkTodoRequest
  checkTodoCodeActions
  checkDirectImportsAndSave

end RunAtTest.RequestSurfaceTest

def main := RunAtTest.RequestSurfaceTest.main
