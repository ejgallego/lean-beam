/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Compiler.IR
import Lean.Elab.Term
import Lean.Shell
import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import RunAt.Internal.SaveSupport
import RunAt.Requests.DiagnosticsCompat
import RunAt.Lib.Handles
import RunAt.Lib.Support

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM
open RunAt.Lib

namespace RunAt.Requests

private def legacyIREmitCName : Name :=
  .str (.str (.str .anonymous "Lean") "IR") "emitC"

-- Lean v4.30 moved C emission from `Lean.IR.emitC` to `Lean.Compiler.LCNF.emitC`.
-- Select the available API at elaboration time so one source tree still builds on v4.28-v4.31.
elab "emitCForSavedModule(" env:term ", " modName:term ")" : term => do
  if (← getEnv).contains legacyIREmitCName then
    Lean.Elab.Term.elabTerm (← `(term| IO.ofExcept <| Lean.IR.emitC $env $modName)) none
  else
    Lean.Elab.Term.elabTerm (← `(term| (Lean.Compiler.LCNF.emitC $modName).toIO'
        { fileName := "", fileMap := default }
        { env := $env })) none

def mkFilePath (path : String) : System.FilePath :=
  System.FilePath.mk path

def ensureParentDir (path : System.FilePath) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent

private def removeFileIfExists (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then
    IO.FS.removeFile path

private def withTempSibling (path : System.FilePath) (writeTemp : System.FilePath → IO Unit) : IO Unit := do
  ensureParentDir path
  let tmp := System.FilePath.mk s!"{path.toString}.beam-tmp-{← IO.monoNanosNow}"
  try
    writeTemp tmp
    removeFileIfExists path
    IO.FS.rename tmp path
  catch e =>
    try
      removeFileIfExists tmp
    catch _ =>
      pure ()
    throw e

private def writeFileReplacing (path : System.FilePath) (content : String) : IO Unit :=
  withTempSibling path fun tmp => IO.FS.writeFile tmp content

private def writeModuleReplacing (env : Environment) (path : System.FilePath) : IO Unit :=
  withTempSibling path fun tmp => Lean.writeModule env tmp

private def emitLLVMReplacing (env : Environment) (mainModule : Name) (path : System.FilePath) : IO Unit :=
  withTempSibling path fun tmp => Lean.IR.emitLLVM env mainModule tmp.toString

def writeIlean
    (doc : DocumentMeta)
    (headerStx : Syntax)
    (mainModule : Name)
    (trees : Array Elab.InfoTree)
    (ileanFile : System.FilePath) : IO Unit := do
  let references := Lean.Server.findModuleRefs doc.text trees (localVars := false)
  let (moduleRefs, decls) ← references.toLspModuleRefs
  let ilean : Lean.Server.Ilean := {
    module := mainModule
    directImports := Lean.Server.collectImports ⟨headerStx⟩
    references := moduleRefs
    decls
  }
  writeFileReplacing ileanFile (Json.compress <| toJson ilean)

def singleLineText (text : String) : String :=
  let parts := text.splitOn "\n"
  let parts := parts.filterMap fun part =>
    let trimmed := part.trimAscii.toString
    if trimmed.isEmpty then none else some trimmed
  String.intercalate " " parts

def formatErrorDiagnostic (diagnostic : Lean.Widget.InteractiveDiagnostic) : String :=
  let line := diagnostic.range.start.line + 1
  let character := diagnostic.range.start.character + 1
  s!"{line}:{character}: {singleLineText diagnostic.message.stripTags}"

def summarizeErrorItems (items : Array String) (maxItems : Nat := 3) : String :=
  let limit := Nat.min maxItems items.size
  let shown := items.extract 0 limit
  let extra := items.size - shown.size
  let suffix := if extra > 0 then s!" (and {extra} more)" else ""
  s!"{String.intercalate " | " shown.toList}{suffix}"

def saveArtifactsErrorMessage
    (diagnosticErrors : Array Lean.Widget.InteractiveDiagnostic)
    (commandErrors : Array String) : String :=
  let detailParts : List String :=
    if !commandErrors.isEmpty then
      [s!"commandMessages: {summarizeErrorItems commandErrors}"]
    else
      [
        if !diagnosticErrors.isEmpty then
          some s!"diagnostics: {summarizeErrorItems (diagnosticErrors.map formatErrorDiagnostic)}"
        else
          none
      ].filterMap id
  if detailParts.isEmpty then
    "cannot save artifacts for a document with errors"
  else
    s!"cannot save artifacts for a document with errors; {String.intercalate "; " detailParts}"

def saveReadinessDocumentErrorsReason : String :=
  "documentErrors"

def saveReadinessNotElaboratedReason : String :=
  "documentDidNotElaborateSuccessfully"

private def snapshotMessageLog (snaps : List Snapshots.Snapshot) : MessageLog :=
  snaps.foldl (fun log snap => log ++ snap.msgLog) MessageLog.empty

private def messageSeverityCount (severity : MessageSeverity) (messages : Array Lean.Message) : Nat :=
  messages.foldl (init := 0) fun count msg =>
    if msg.severity == severity then count + 1 else count

private def commandErrorMessages (messages : Array Lean.Message) : RequestM (Array String) := do
  let mut commandErrors : Array String := #[]
  for msg in messages do
    if msg.severity == MessageSeverity.error then
      commandErrors := commandErrors.push (singleLineText (← msg.data.toString))
  pure commandErrors

private def saveBlockingDiagnosticOfInteractive
    (diagnostic : Lean.Widget.InteractiveDiagnostic) : RunAt.Internal.SaveBlockingDiagnostic :=
  let plain := Lean.Widget.InteractiveDiagnostic.toDiagnostic diagnostic
  {
    range := diagnostic.fullRange
    severity? := plain.severity?
    message := singleLineText plain.message
    saveBlocking := true
    completionBlocking := false
  }

private def saveBlockingDiagnosticsOfMessages
    (doc : Lean.Server.FileWorker.EditableDocument)
    (messages : Array Lean.Message) : RequestM (Array RunAt.Internal.SaveBlockingDiagnostic) := do
  let mut blockingDiagnostics := #[]
  for msg in messages do
    if msg.severity == MessageSeverity.error then
      let diagnostic ← Lean.Widget.msgToInteractiveDiagnostic doc.meta.text msg false
      blockingDiagnostics := blockingDiagnostics.push (saveBlockingDiagnosticOfInteractive diagnostic)
  pure blockingDiagnostics

private def saveBlockingDiagnosticsOfInteractive
    (diagnostics : Array Lean.Widget.InteractiveDiagnostic) :
    Array RunAt.Internal.SaveBlockingDiagnostic :=
  diagnostics.map saveBlockingDiagnosticOfInteractive

private def saveBlockingCommandMessages
    (messages : Array String) : Array RunAt.Internal.SaveBlockingCommandMessage :=
  messages.map fun message => {
    message
    saveBlocking := true
    completionBlocking := false
  }

def collectSaveReadiness
    (doc : Lean.Server.FileWorker.EditableDocument)
    (snaps : List Snapshots.Snapshot) :
    RequestM
      (RunAt.Internal.SaveReadinessResult ×
        Option Elab.Command.State ×
        Array Lean.Widget.InteractiveDiagnostic ×
        Array String) := do
  let diagnostics ← collectCurrentDiagnosticsCompat(doc)
  let diagnosticErrors := diagnostics.filter (fun diag => diag.severity? == some .error)
  let diagnosticWarnings := diagnostics.filter (fun diag => diag.severity? == some .warning)
  -- Mirror Lean server/frontend snapshot-log aggregation, and use the exported upstream
  -- predicate for the boolean decision.
  let frontendLog := snapshotMessageLog snaps
  let frontendMessages := frontendLog.reportedPlusUnreported.toArray
  let frontendErrorCount := messageSeverityCount MessageSeverity.error frontendMessages
  let frontendWarningCount := messageSeverityCount MessageSeverity.warning frontendMessages
  let commandErrors ← commandErrorMessages frontendMessages
  let frontendBlockingDiagnostics ← saveBlockingDiagnosticsOfMessages doc frontendMessages
  let frontendBlockingCommandMessages := saveBlockingCommandMessages commandErrors
  let fallbackBlockingDiagnostics :=
    if frontendErrorCount == 0 then
      saveBlockingDiagnosticsOfInteractive diagnosticErrors
    else
      frontendBlockingDiagnostics
  let fallbackBlockingCommandMessages :=
    if frontendErrorCount == 0 then #[] else frontendBlockingCommandMessages
  let some cmdState := Lean.Language.Lean.waitForFinalCmdState? doc.initSnap
    | return ({
      version := doc.meta.version
      saveBlockingErrorCount :=
        if frontendErrorCount == 0 then diagnosticErrors.size else frontendErrorCount
      currentWarningCount :=
        if frontendWarningCount == 0 then diagnosticWarnings.size else frontendWarningCount
      commandErrorCount := commandErrors.size
      saveReady := false
      saveReadyReason := saveReadinessNotElaboratedReason
      saveReadyMessage? := some (saveArtifactsErrorMessage diagnosticErrors commandErrors)
      blockingDiagnostics := fallbackBlockingDiagnostics
      blockingCommandMessages := fallbackBlockingCommandMessages
      : RunAt.Internal.SaveReadinessResult
    }, none, diagnosticErrors, commandErrors)
  let saveReady := !frontendLog.hasErrors
  let readiness : RunAt.Internal.SaveReadinessResult := {
    version := doc.meta.version
    saveBlockingErrorCount := frontendErrorCount
    currentWarningCount :=
      if frontendWarningCount == 0 then diagnosticWarnings.size else frontendWarningCount
    commandErrorCount := commandErrors.size
    saveReady := saveReady
    saveReadyReason := if saveReady then "ok" else saveReadinessDocumentErrorsReason
    saveReadyMessage? :=
      if saveReady then none else some (saveArtifactsErrorMessage diagnosticErrors commandErrors)
    blockingDiagnostics := if saveReady then #[] else frontendBlockingDiagnostics
    blockingCommandMessages := if saveReady then #[] else frontendBlockingCommandMessages
  }
  pure (readiness, some cmdState, diagnosticErrors, commandErrors)

def saveCurrentArtifacts
    (doc : Lean.Server.FileWorker.EditableDocument)
    (snaps : List Snapshots.Snapshot)
    (p : RunAt.Internal.SaveArtifactsParams) : RequestM RunAt.Internal.SaveArtifactsResult := do
  checkRequestCancelled
  let (readiness, cmdState?, diagnosticErrors, commandErrors) ← collectSaveReadiness doc snaps
  unless readiness.saveReady do
    throw <| RequestError.invalidParams (saveArtifactsErrorMessage diagnosticErrors commandErrors)
  let some cmdState := cmdState?
    | throw <| RequestError.invalidParams "document did not elaborate successfully"
  let env := cmdState.env
  let mainModule := env.mainModule
  let oleanFile := mkFilePath p.oleanFile
  let ileanFile := mkFilePath p.ileanFile
  let cFile := mkFilePath p.cFile
  writeModuleReplacing env oleanFile
  let trees := snaps.toArray.map (·.infoTree)
  writeIlean doc.meta doc.initSnap.stx mainModule trees ileanFile
  let cOutput ← emitCForSavedModule(env, mainModule)
  writeFileReplacing cFile cOutput
  if let some bcFile := p.bcFile?.map mkFilePath then
    emitLLVMReplacing env mainModule bcFile
  checkRequestCancelled
  pure {
    written := true
    version := doc.meta.version
    textHash := hash doc.meta.text.source
  }

def handleSaveArtifacts
    (p : RunAt.Internal.SaveArtifactsParams) :
    RequestM (RequestTask RunAt.Internal.SaveArtifactsResult) := do
  syncHandleStoreForCurrentDoc
  let doc ← RequestM.readDoc
  let t := doc.cmdSnaps.waitAll
  RequestM.mapTaskCostly t fun (snaps, _) => do
    saveCurrentArtifacts doc snaps p

def handleSaveReadiness
    (_p : RunAt.Internal.SaveReadinessParams) :
    RequestM (RequestTask RunAt.Internal.SaveReadinessResult) := do
  syncHandleStoreForCurrentDoc
  let doc ← RequestM.readDoc
  let t := doc.cmdSnaps.waitAll
  RequestM.mapTaskCostly t fun (snaps, _) => do
    let (readiness, _, _, _) ← collectSaveReadiness doc snaps
    pure readiness

end RunAt.Requests
