/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Scenario
import Beam.LSP.DirectImports
import Beam.LSP.Save
import BeamTest.Fixtures.TodoFixture

open Lean
open BeamTest.LSP.Scenario

namespace BeamTest.LSP.RequestSurfaceTest

private def expectFileExists (label : String) (path : System.FilePath) : ScenarioM Unit := do
  unless ← path.pathExists do
    throw <| IO.userError s!"{label}: expected file {path} to exist"

private def requireSingleGoalTarget (label expectedNeedle : String) (state : Beam.LSP.Lib.ProofState) :
    ScenarioM Unit := do
  let some goal := state.goals[0]?
    | throw <| IO.userError s!"{label}: expected one goal"
  unless goal.target.contains expectedNeedle do
    throw <| IO.userError s!"{label}: expected target to contain '{expectedNeedle}', got '{goal.target}'"

private def requireTodoKind (label : String) (kind : Beam.LSP.Todo.TodoKind) (result : Beam.LSP.Todo.TodoResult) :
    ScenarioM Beam.LSP.Todo.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind)
    | throw <| IO.userError s!"{label}: expected todo kind {kind.key}, got {(toJson result).compress}"
  pure item

private def requireNoTodoKind (label : String) (kind : Beam.LSP.Todo.TodoKind) (result : Beam.LSP.Todo.TodoResult) :
    ScenarioM Unit := do
  if result.items.any (fun item => item.kind == kind) then
    throw <| IO.userError s!"{label}: unexpected todo kind {kind.key}: {(toJson result).compress}"

private def countTodoKind (kind : Beam.LSP.Todo.TodoKind) (result : Beam.LSP.Todo.TodoResult) : Nat :=
  result.items.foldl (init := 0) fun count item =>
    if item.kind == kind then count + 1 else count

private def requireTodoKindCount
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (expected : Nat)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Unit := do
  let actual := countTodoKind kind result
  unless actual == expected do
    throw <| IO.userError
      s!"{label}: expected {expected} todo items of kind {kind.key}, got {actual}: {(toJson result).compress}"

private def requireTodoKindAtLeast
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (expected : Nat)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Unit := do
  let actual := countTodoKind kind result
  unless expected <= actual do
    throw <| IO.userError
      s!"{label}: expected at least {expected} todo items of kind {kind.key}, got {actual}: {(toJson result).compress}"

private def requireRangeEq (label : String) (expected actual : Lean.Lsp.Range) : ScenarioM Unit := do
  unless actual == expected do
    throw <| IO.userError s!"{label}: expected range {repr expected}, got {repr actual}"

private def todoMessageContains (needle : String) (item : Beam.LSP.Todo.TodoItem) : Bool :=
  match item.message? with
  | some message => message.contains needle
  | none => false

private def requireTodoKindWithMessage
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (needle : String)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Beam.LSP.Todo.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind && todoMessageContains needle item)
    | throw <| IO.userError
        s!"{label}: expected todo kind {kind.key} with message containing '{needle}', got {(toJson result).compress}"
  pure item

private def requireDiagnosticSeverity
    (label : String)
    (severity : Lean.Lsp.DiagnosticSeverity)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Unit := do
  unless result.items.any (fun item => item.kind == .diagnostic && item.severity? == some severity) do
    throw <| IO.userError
      s!"{label}: expected diagnostic severity {(toJson severity).compress}, got {(toJson result).compress}"

private def requireRunAtSuccess
    (label : String)
    (doc : DocHandle)
    (position : Lean.Lsp.Position)
    (text : String) : ScenarioM Beam.LSP.RunAt.Result := do
  let req ← sendRunAt doc {
    line := position.line
    character := position.character
    text
  }
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
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

private def requireRunAtFailureMessage
    (label : String)
    (doc : DocHandle)
    (position : Lean.Lsp.Position)
    (text : String)
    (needle : String) : ScenarioM Unit := do
  let req ← sendRunAt doc {
    line := position.line
    character := position.character
    text
  }
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
  if result.success then
    throw <| IO.userError s!"{label}: expected runAt failure, got {(toJson result).compress}"
  unless result.messages.any (fun msg => msg.severity == MessageSeverity.error && msg.text.contains needle) do
    throw <| IO.userError
      s!"{label}: expected error message containing '{needle}', got {(toJson result).compress}"

private def mkTmpDir (stem : String) : ScenarioM System.FilePath := do
  let dir := System.FilePath.mk s!"/tmp/{stem}-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  pure dir

private def checkRunAtOneCommandOnly : ScenarioM Unit := do
  let doc ← openDoc "BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt command sequence" doc { line := 8, character := 0 }
    "def runAtOneCommandA : Nat := 1\n\n#check runAtOneCommandA"
    "runAtSupportsOneCommandOnly"
  closeDoc doc

private def checkRunAtTheoremProofFailure : ScenarioM Unit := do
  let doc ← openDoc "BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem proof failure" doc { line := 8, character := 0 }
    "theorem runAtImpossibleProbe : False := by\n  trivial"
    "False"
  closeDoc doc

private def checkRunAtTheoremTacticFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TopLevelTheoremRunAtFailure.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem tactic failure" doc { line := 7, character := 0 }
    "theorem runAtTacticFailureProbe : True := by\n  runat_fail_tac"
    "runAt custom tactic failure"
  closeDoc doc

private def checkGoalsRequests : ScenarioM Unit := do
  let doc ← openDoc "tests/save_olean_project/GoalSmoke.lean"

  let goalsPrevReq ← sendGoals doc { line := 1, character := 2, useAfter := false }
  let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsPrevReq
  if goalsPrev.goals.size != 1 then
    throw <| IO.userError s!"goals prev: expected one goal, got {goalsPrev.goals.size}"
  requireSingleGoalTarget "goals prev" "True" goalsPrev

  let goalsAfterReq ← sendGoals doc { line := 1, character := 2, useAfter := true }
  let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsAfterReq
  if goalsAfter.goals.size != 0 then
    throw <| IO.userError s!"goals after: expected solved proof state, got {goalsAfter.goals.size} goals"

  closeDoc doc

private def checkTodoRequest : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.repoPath
  syncDoc doc

  let allReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.endLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    suggest? := some .basic
  }
  let allTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs allReq
  let sorryItem ← requireTodoKind "todo all" .sorry allTodos
  if countTodoKind .sorry allTodos != 1 then
    throw <| IO.userError s!"todo all: expected one actionable sorry, got {(toJson allTodos).compress}"
  if sorryItem.range.start != BeamTest.Fixtures.TodoFixture.sorryPosition then
    throw <| IO.userError
      s!"todo all: expected sorry token range at {BeamTest.Fixtures.TodoFixture.sorryPosition}, got {(toJson sorryItem).compress}"
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
  let pointIncompleteTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs pointIncompleteReq
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
    startLine := BeamTest.Fixtures.TodoFixture.endLine
    startCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    endLine := BeamTest.Fixtures.TodoFixture.startLine
    endCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
  }
  let reversedOutcome ← awaitReq reversedReq
  if reversedOutcome.errorCode? != some "invalidParams" then
    throw <| IO.userError
      s!"todo reversed range: expected invalidParams, got {reversedOutcome.errorCode?.getD "normal response"}: {reversedOutcome.errorMessage}"

  let skippedSorryReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.skippedSorryEndLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    kinds? := some #[.sorry]
  }
  let skippedSorryTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs skippedSorryReq
  if !skippedSorryTodos.items.isEmpty then
    throw <| IO.userError s!"todo skipped sorry text: expected no actionable sorry, got {(toJson skippedSorryTodos).compress}"

  let sorryReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.endLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    kinds? := some #[.sorry]
    suggest? := some .none
  }
  let sorryTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs sorryReq
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
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.codeActionRepoPath
  syncDoc doc

  let codeActionReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.codeActionLine
    startCharacter := BeamTest.Fixtures.TodoFixture.codeActionStartCharacter
    endLine := BeamTest.Fixtures.TodoFixture.codeActionLine
    endCharacter := BeamTest.Fixtures.TodoFixture.codeActionEndCharacter
    kinds? := some #[.codeAction]
  }
  let codeActionTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs codeActionReq
  let actionItem ← requireTodoKind "todo code action fixture" .codeAction codeActionTodos
  if countTodoKind .codeAction codeActionTodos != 1 then
    throw <| IO.userError
      s!"todo code action fixture: expected one code action, got {(toJson codeActionTodos).compress}"
  requireRangeEq "todo code action fixture"
    BeamTest.Fixtures.TodoFixture.codeActionRange actionItem.range
  if actionItem.runAtPosition != BeamTest.Fixtures.TodoFixture.codeActionRange.start then
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

private def checkComplexTodoFalsePositives (doc : DocHandle) : ScenarioM Unit := do
  let falsePositiveReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexFalsePositiveStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexFalsePositiveEndLine
    endCharacter := 0
    kinds? := some #[.sorry]
  }
  let falsePositiveTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs falsePositiveReq
  if !falsePositiveTodos.items.isEmpty then
    throw <| IO.userError
      s!"todo complex false positives: expected no actionable sorry in comments/strings/quoted identifiers, got {(toJson falsePositiveTodos).compress}"

private def checkComplexTodoSemanticItems (doc : DocHandle) : ScenarioM Unit := do
  let semanticReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexStartLine
    startCharacter := BeamTest.Fixtures.TodoFixture.complexStartCharacter
    endLine := BeamTest.Fixtures.TodoFixture.complexEndLine
    endCharacter := BeamTest.Fixtures.TodoFixture.complexEndCharacter
    kinds? := some #[.sorry, .hole]
  }
  let semanticTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs semanticReq
  requireTodoKindCount "todo complex semantic sorries" .sorry 2 semanticTodos
  requireTodoKindCount "todo complex semantic holes" .hole 3 semanticTodos
  requireNoTodoKind "todo complex semantic filter" .diagnostic semanticTodos
  requireNoTodoKind "todo complex semantic filter" .codeAction semanticTodos
  requireNoTodoKind "todo complex semantic filter" .incompleteProof semanticTodos

  let sorryItem ← requireTodoKind "todo complex sorry/runAt composition" .sorry semanticTodos
  requireRunAtSolvesProof "todo complex sorry/runAt composition" doc sorryItem.runAtPosition "exact trivial"

private def checkComplexTodoIncompleteProofs (doc : DocHandle) : ScenarioM Unit := do
  let incompleteReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexIncompleteOneStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexIncompleteOneEndLine
    endCharacter := 0
    kinds? := some #[.incompleteProof]
    suggest? := some .basic
  }
  let incompleteTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs incompleteReq
  requireTodoKindCount "todo complex single incomplete proof" .incompleteProof 1 incompleteTodos
  let incomplete ← requireTodoKind "todo complex single incomplete proof" .incompleteProof incompleteTodos
  if incomplete.runAtText? != some "exact ?_" then
    throw <| IO.userError
      s!"todo complex single incomplete proof: expected basic runAtText, got {(toJson incomplete).compress}"
  let some proofState := incomplete.proofState?
    | throw <| IO.userError
        s!"todo complex single incomplete proof: expected proofState, got {(toJson incomplete).compress}"
  requireSingleGoalTarget "todo complex single incomplete proof" "True" proofState
  requireRunAtSolvesProof "todo complex incomplete/runAt composition" doc incomplete.runAtPosition "exact trivial"

  let branchReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexBranchSkipStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexBranchSkipEndLine
    endCharacter := 0
    kinds? := some #[.incompleteProof]
    suggest? := some .none
  }
  let branchTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs branchReq
  requireTodoKindCount "todo complex branch incomplete proof" .incompleteProof 1 branchTodos
  let branch ← requireTodoKind "todo complex branch incomplete proof" .incompleteProof branchTodos
  if branch.runAtText?.isSome then
    throw <| IO.userError
      s!"todo complex branch incomplete proof: expected suggest=none to omit runAtText, got {(toJson branch).compress}"
  let some branchProofState := branch.proofState?
    | throw <| IO.userError
        s!"todo complex branch incomplete proof: expected proofState, got {(toJson branch).compress}"
  requireSingleGoalTarget "todo complex branch incomplete proof" "True" branchProofState
  requireRunAtSolvesProof "todo complex branch/runAt composition" doc branch.runAtPosition "exact trivial"

private def checkComplexTodoDiagnostics (doc : DocHandle) : ScenarioM Unit := do
  let warningReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexSorryStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexSorryEndLine
    endCharacter := 0
    kinds? := some #[.diagnostic]
  }
  let warningTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs warningReq
  requireTodoKindAtLeast "todo complex warning diagnostic" .diagnostic 1 warningTodos
  requireDiagnosticSeverity "todo complex warning diagnostic" .warning warningTodos

  let diagnosticReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexDiagnosticLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexDiagnosticLine
    endCharacter := BeamTest.Fixtures.TodoFixture.complexDiagnosticEndCharacter
    kinds? := some #[.diagnostic]
  }
  let diagnosticTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs diagnosticReq
  requireTodoKindAtLeast "todo complex error diagnostic" .diagnostic 1 diagnosticTodos
  requireDiagnosticSeverity "todo complex error diagnostic" .error diagnosticTodos
  discard <| requireTodoKindWithMessage "todo complex error diagnostic"
    .diagnostic "Type mismatch" diagnosticTodos

private def checkTodoInteractiveOnlyDiagnostic : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/InteractiveOnlyDiagnostic.lean"
  syncDoc doc

  let diagnosticReq ← sendTodo doc {
    startLine := 20
    startCharacter := 0
    endLine := 21
    endCharacter := 0
    kinds? := some #[.diagnostic]
  }
  let diagnosticTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs diagnosticReq
  requireTodoKindAtLeast "todo interactive-only diagnostic" .diagnostic 1 diagnosticTodos
  requireDiagnosticSeverity "todo interactive-only diagnostic" .error diagnosticTodos
  discard <| requireTodoKindWithMessage "todo interactive-only diagnostic"
    .diagnostic "interactive-only diagnostic from child snapshot" diagnosticTodos

  closeDoc doc

private def checkComplexTodoCodeActions (doc : DocHandle) : ScenarioM Unit := do
  let codeActionReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexCodeActionLine
    startCharacter := BeamTest.Fixtures.TodoFixture.complexCodeActionStartCharacter
    endLine := BeamTest.Fixtures.TodoFixture.complexCodeActionLine
    endCharacter := BeamTest.Fixtures.TodoFixture.complexCodeActionEndCharacter
    kinds? := some #[.codeAction]
  }
  let codeActionTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs codeActionReq
  let actionItem ← requireTodoKindWithMessage "todo complex code action"
    .codeAction "Fill complex fixture hole with zero" codeActionTodos
  let some action := actionItem.codeAction?
    | throw <| IO.userError
        s!"todo complex code action: expected embedded codeAction payload, got {(toJson actionItem).compress}"
  if action.edit?.isNone then
    throw <| IO.userError
      s!"todo complex code action: expected edit payload, got {(toJson action).compress}"

private def checkComplexTodoRequest : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.complexRepoPath
  syncDoc doc

  checkComplexTodoFalsePositives doc
  checkComplexTodoSemanticItems doc
  checkComplexTodoIncompleteProofs doc
  checkComplexTodoDiagnostics doc
  checkComplexTodoCodeActions doc

  closeDoc doc

private def checkDirectImportsAndSave : ScenarioM Unit := do
  let doc ← openDoc "BeamTest/Fixtures/Deps/DepA.lean"

  let importsReq ← sendDirectImports doc
  let imports : Beam.LSP.DirectImports.DirectImportsResult ← awaitResponseAs importsReq
  if imports.version != 1 then
    throw <| IO.userError s!"directImports: expected version 1, got {imports.version}"
  if imports.imports != #["BeamTest.Fixtures.Deps.DepB"] then
    throw <| IO.userError s!"directImports: unexpected imports {(toJson imports.imports).compress}"

  let readinessReq ← sendSaveReadiness doc
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError s!"saveReadiness: expected saveReady = true, got {(toJson readiness).compress}"
  if readiness.saveReadyReason != "ok" then
    throw <| IO.userError s!"saveReadiness: expected reason = ok, got {readiness.saveReadyReason}"
  unless readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty do
    throw <| IO.userError
      s!"saveReadiness: expected clean file to omit save-blocking evidence, got {(toJson readiness).compress}"

  let staleReadinessVersionReq ← sendSaveReadiness doc {
    expectedVersionOverride? := some 0
  }
  expectErrorContains staleReadinessVersionReq (Json.mkObj [("code", toJson "contentModified")])

  let depAText ← IO.FS.readFile "BeamTest/Fixtures/Deps/DepA.lean"
  let staleTextHash := if hash depAText == 0 then 1 else 0
  let staleReadinessHashReq ← sendSaveReadiness doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some staleTextHash
  }
  expectErrorContains staleReadinessHashReq (Json.mkObj [("code", toJson "contentModified")])

  let outDir ← mkTmpDir "runat-request-surface"
  let staleVersionReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 0
    oleanFile := (outDir / "StaleVersion.olean").toString
    ileanFile := (outDir / "StaleVersion.ilean").toString
    cFile := (outDir / "StaleVersion.c").toString
  }
  expectErrorContains staleVersionReq (Json.mkObj [("code", toJson "contentModified")])

  let staleHashReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some staleTextHash
    oleanFile := (outDir / "StaleHash.olean").toString
    ileanFile := (outDir / "StaleHash.ilean").toString
    cFile := (outDir / "StaleHash.c").toString
  }
  expectErrorContains staleHashReq (Json.mkObj [("code", toJson "contentModified")])

  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash depAText)
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }
  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs saveReq
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
  let broken : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs brokenReq
  if broken.saveReady then
    throw <| IO.userError s!"broken saveReadiness: expected saveReady = false, got {(toJson broken).compress}"
  if broken.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"broken saveReadiness: expected reason = documentErrors, got {broken.saveReadyReason}"
  if broken.blockingDiagnostics.isEmpty && broken.blockingCommandMessages.isEmpty then
    throw <| IO.userError
      s!"broken saveReadiness: expected save-blocking evidence, got {(toJson broken).compress}"
  unless broken.blockingDiagnostics.all (·.saveBlocking) &&
      broken.blockingCommandMessages.all (·.saveBlocking) do
    throw <| IO.userError
      s!"broken saveReadiness: expected blocking evidence to carry saveBlocking=true, got {(toJson broken).compress}"

  closeDoc doc

private def checkReportedOnlyErrorReadiness : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/ReportedOnlyError.lean"
  syncDoc doc

  let readinessReq ← sendSaveReadiness doc
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError
      s!"reported-only saveReadiness: expected saveReady = true, got {(toJson readiness).compress}"
  unless readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty do
    throw <| IO.userError
      s!"reported-only saveReadiness: expected no save-blocking evidence, got {(toJson readiness).compress}"

  closeDoc doc

def main : IO Unit := BeamTest.LSP.Scenario.run do
  checkRunAtOneCommandOnly
  checkRunAtTheoremProofFailure
  checkRunAtTheoremTacticFailure
  checkGoalsRequests
  checkTodoRequest
  checkTodoCodeActions
  checkComplexTodoRequest
  checkTodoInteractiveOnlyDiagnostic
  checkDirectImportsAndSave
  checkReportedOnlyErrorReadiness

end BeamTest.LSP.RequestSurfaceTest

def main := BeamTest.LSP.RequestSurfaceTest.main
