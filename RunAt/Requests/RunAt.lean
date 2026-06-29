/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import RunAt.Lib.Goals
import RunAt.Lib.Handles
import RunAt.Lib.Support

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM
open RunAt.Lib

namespace RunAt.Requests

def runAtSupportsOneCommandOnlyCode : String :=
  "runAtSupportsOneCommandOnly"

private inductive CommandParseResult where
  | ok (stx : Syntax)
  | extraInput (err : String)
  | error (err : String)

private def parseOneCommandText (env : Environment) (text : String) : CommandParseResult :=
  let p := Parser.andthenFn Parser.whitespace (Parser.categoryParserFnImpl `command)
  let ictx := Parser.mkInputContext text "<runAt>"
  let s := p.run ictx { env, options := {} } (Parser.getTokenTable env) (Parser.mkParserState text)
  if !s.allErrors.isEmpty then
    .error (s.toErrorMsg ictx)
  else if ictx.atEnd s.pos then
    .ok s.stxStack.back
  else
    .extraInput ((s.mkError "end of input").toErrorMsg ictx)

private def oneCommandOnlyResult (err : String) : Result :=
  errorResult
    s!"{runAtSupportsOneCommandOnlyCode}: command-mode runAt accepts exactly one Lean command, not a top-level command sequence. Use a stored handle continuation for explicit speculative sequencing, or write the sequence to the file and sync it. Original parse error: {err}"

-- With `Elab.async`, `elabCommandTopLevel` may return before nested work has produced its
-- diagnostics. Top-level theorem commands use this path for proof-body elaboration, so these
-- snapshot messages are part of the command-mode `runAt` result even though unrelated full-file
-- diagnostics remain out of scope.
private def collectSnapshotTaskArtifacts
    (tasks : Array (Language.SnapshotTask Language.SnapshotTree)) :
    BaseIO (List Lean.Message × List TraceElem) := do
  if tasks.isEmpty then
    return ([], [])
  let tree := Language.SnapshotTree.mk { diagnostics := .empty } tasks
  let waitTask ← tree.waitAll
  -- Force every child snapshot before reading the tree; otherwise theorem proof failures can be
  -- hidden behind unfinished async tasks.
  let _ := waitTask.get
  let snapshots := tree.getAll
  let messages := snapshots.foldl (init := []) fun acc snapshot =>
    acc ++ snapshot.diagnostics.msgLog.toList
  let traces := snapshots.foldl (init := []) fun acc snapshot =>
    acc ++ snapshot.traces.traces.toList
  return (messages, traces)

def runCommandText (snap : Snapshots.Snapshot) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let rc ← readThe RequestContext
    let stx ←
      match parseOneCommandText snap.env text with
      | .ok stx => pure stx
      | .extraInput err => return (oneCommandOnlyResult err, none)
      | .error err => return (errorResult err, none)
    let (output, response) ← IO.FS.withIsolatedStreams do
      EIO.toBaseIO do
        runCommandElabMWithCancel snap rc.doc.meta (some innerCancelTk) do
          -- The incoming snapshot can carry already-accounted-for async work from the saved file.
          -- A speculative command result should include only tasks spawned by this command.
          modify fun state => { state with snapshotTasks := #[] }
          let initialMsgCount := (← get).messages.toList.length
          let initialTraceCount := (← getTraces).size
          let error? ← try
            Elab.Command.elabCommandTopLevel stx
            pure none
          catch ex =>
            if ex.isInterrupt then
              throw ex
            pure (some (← ex.toMessageData.toString))
          let state ← get
          let messages := state.messages.toList.drop initialMsgCount
          let traces := (← getTraces).toList.drop initialTraceCount
          let (snapshotMessages, snapshotTraces) ←
            collectSnapshotTaskArtifacts state.snapshotTasks
          return (
            error?,
            messages ++ snapshotMessages,
            traces ++ snapshotTraces,
            -- Completed snapshot tasks have been folded into the result. Do not leak them into a
            -- stored command handle, where a later `runWith` would report them again.
            { state with snapshotTasks := #[] })
    let (error?, newMessages, newTraces, newState) ←
      match response with
      | .ok response => pure response
      | .error ex =>
          checkRequestCancelled
          throw <| RequestError.internalError (← ex.toMessageData.toString)
    let artifacts ← mkExecutionArtifacts output newMessages newTraces
    checkRequestCancelled
    let result := mkExecutionResult error? artifacts
    let nextHandle? :=
      if result.success then
        some <| StoredHandleState.command { snap with cmdState := newState }
      else
        none
    return (result, nextHandle?)

def proofStateOfSnapshot (snapshot : ProofSnapshot) : RequestM ProofState := do
  let (proofState, _) ← snapshot.runMetaM <| proofStateOfGoalList snapshot.tacticState.goals
  return proofState

def runTacticText (snapshot : ProofSnapshot) (initialProofState : ProofState) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let snapshot := snapshot.withCancelToken (some innerCancelTk)
    let stx ←
      match Parser.runParserCategory snapshot.coreState.env `tactic text "<runAt>" with
      | .ok stx => pure stx
      | .error err => return (errorResult err (some initialProofState), none)
    let (output, ((error?, newMessages, newTraces), proofSnapshot')) ←
      try
        IO.FS.withIsolatedStreams do
          let run := snapshot.runTacticM do
            let saved ← Elab.Tactic.saveState
            let initialMsgCount := (← Core.getMessageLog).toList.length
            let initialTraceCount := (← getTraces).size
            let error? ← try
              Elab.Tactic.evalTactic stx
              pure none
            catch ex =>
              if ex.isInterrupt then
                throw ex
              saved.restore (restoreInfo := true)
              pure (some (← ex.toMessageData.toString))
            let messages := (← Core.getMessageLog).toList.drop initialMsgCount
            let traces := (← getTraces).toList.drop initialTraceCount
            return ((error?, messages, traces))
          run
      catch ex =>
        checkRequestCancelled
        throw ex
    let artifacts ← mkExecutionArtifacts output newMessages newTraces
    checkRequestCancelled
    let proofState ←
      if error?.isSome then
        pure initialProofState
      else
        proofStateOfSnapshot proofSnapshot'
    let result := mkExecutionResult error? artifacts (proofState? := some proofState)
    let nextHandle? :=
      if result.success then
        some <| StoredHandleState.proof proofSnapshot'
      else
        none
    return (result, nextHandle?)

def runTacticAtBasis (basis : GoalsAtResult) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  let ctxInfo := mkBasisCtxInfo basis
  let initialProofState ← basisProofState basis
  let proofSnapshot ← ProofSnapshot.create ctxInfo (basisGoals basis)
  runTacticText proofSnapshot initialProofState text

def handleRunAt (p : Params) : RequestM (RequestTask Result) := do
  requireDocumentVersion p.textDocument
  syncHandleStoreForCurrentDoc
  validatePosition p.position
  checkRequestCancelled
  let proofTask ← findProofBasisAt p.position
  RequestM.bindRequestTaskCostly proofTask <| fun
    | some basis => do
        checkRequestCancelled
        let (result, state?) ← runTacticAtBasis basis p.text
        return RequestTask.pure (← maybeAttachHandle result (p.storeHandle?.getD false) state?)
    | none =>
        withRunAtSnapAtPos p.position fun snap => do
          checkRequestCancelled
          let (result, state?) ← runCommandText snap p.text
          maybeAttachHandle result (p.storeHandle?.getD false) state?

def handleRunWith (p : RunWithParams) : RequestM (RequestTask Result) := do
  syncHandleStoreForCurrentDoc
  checkRequestCancelled
  withStoredHandle p.handle (p.linear?.getD false) fun stored => do
    RequestM.asTask do
      checkRequestCancelled
      let (result, state?) ←
        match stored.state with
        | .command snapshot =>
            runCommandText snapshot p.text
        | .proof snapshot =>
            let initialProofState ← proofStateOfSnapshot snapshot
            runTacticText snapshot initialProofState p.text
      maybeAttachHandle result (p.storeHandle?.getD false) state?

def handleReleaseHandle (p : ReleaseHandleParams) : RequestM (RequestTask Json) := do
  syncHandleStoreForCurrentDoc
  releaseStoredHandle p.handle
  return RequestTask.pure Json.null

end RunAt.Requests
