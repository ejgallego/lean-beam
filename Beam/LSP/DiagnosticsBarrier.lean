/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Data.Lsp.Extra
import Lean.Server.References
import Lean.Server.Requests

open Lean
open Lean.Server
open Lean.Server.RequestM

namespace Beam.LSP.DiagnosticsBarrier

/--
Internal Beam diagnostics barrier. This mirrors Lean's `textDocument/waitForDiagnostics`, but
returns small Beam-owned metadata from the accepted document snapshot.
-/
def method : String := "$/beam/waitForDiagnostics"

structure Result where
  version : Nat
  directImports : Array String := #[]
  deriving FromJson, ToJson

private def importsOfHeader (header : Lean.Elab.HeaderSyntax) : Array String :=
  (Lean.Server.collectImports header).foldl (init := #[]) fun acc info =>
    if acc.contains info.module then
      acc
    else
      acc.push info.module

partial def waitForDocumentVersion (version : Nat) : RequestM Lean.Server.FileWorker.EditableDocument := do
  let doc ← readDoc
  if version ≤ doc.meta.version then
    return doc
  else
    IO.sleep 50
    waitForDocumentVersion version

def resultOfDocument (doc : Lean.Server.FileWorker.EditableDocument) : Result := {
  version := doc.meta.version
  directImports := importsOfHeader ⟨doc.initSnap.stx⟩
}

def handle (p : Lean.Lsp.WaitForDiagnosticsParams) : RequestM (RequestTask Result) := do
  let t ← RequestM.asTask <| waitForDocumentVersion p.version
  RequestM.bindTaskCheap t fun doc? => do
    let doc ← liftExcept doc?
    let result := resultOfDocument doc
    -- Match `textDocument/waitForDiagnostics`: wait on both the reporter and `cmdSnaps` so
    -- request handlers using `IO.hasFinished` on `doc.cmdSnaps` have completed.
    return doc.reporter.bindCheap (fun _ => doc.cmdSnaps.waitAll)
      |>.mapCheap fun _ => pure result

end Beam.LSP.DiagnosticsBarrier
