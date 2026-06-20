/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Elab.Term
import Lean.Server.FileWorker.RequestHandling

open Lean
open Lean.Elab

namespace RunAt.Requests

private def collectCurrentDiagnosticsName : Name :=
  .str (.str (.str (.str (.str .anonymous "Lean") "Server") "FileWorker")
    "EditableDocumentCore") "collectCurrentDiagnostics"

-- Lean v4.31 replaced `EditableDocument.diagnosticsRef` with a diagnostics mutex and
-- `EditableDocumentCore.collectCurrentDiagnostics`.
elab "collectCurrentDiagnosticsCompat(" doc:term ")" : term => do
  if (← getEnv).contains collectCurrentDiagnosticsName then
    Lean.Elab.Term.elabTerm (← `(term| (do
      let diagnostics ← Lean.Server.FileWorker.EditableDocumentCore.collectCurrentDiagnostics
        (($doc).toEditableDocumentCore)
      pure diagnostics.toArray))) none
  else
    Lean.Elab.Term.elabTerm (← `(term| (($doc).diagnosticsRef.get))) none

end RunAt.Requests
