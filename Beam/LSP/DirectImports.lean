/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.Requests
import Beam.LSP.Lib.Request

open Lean
open Lean.Server
open Lean.Server.RequestM
open Beam.LSP.Lib

/-
Internal direct-import query used by the broker for stale-dependency hints.

This extension is independent of the execution and save families; it only needs version checking
and cancellation handling from the shared request helpers.
-/
namespace Beam.LSP.DirectImports

/--
Internal broker-only request for parsing the current document header and returning its direct imports
from the current tracked text snapshot.

This supports broker-side stale dependency hints. It is not part of the supported public `runAt`
API.
-/
def method : String := "$/beam/directImports"

/-- Internal request payload for direct-import queries from a known text snapshot. -/
structure DirectImportsParams where
  textDocument : Lean.Lsp.VersionedTextDocumentIdentifier
  deriving FromJson, ToJson

-- Keep this indirection while v4.28 stays supported; re-check this request type when the
-- compatibility target is dropped.
instance : Lean.Lsp.FileSource DirectImportsParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Internal success payload for direct-import queries from the current tracked text snapshot. -/
structure DirectImportsResult where
  version : Nat
  imports : Array String := #[]
  deriving FromJson, ToJson

def handle (p : DirectImportsParams) : RequestM (RequestTask DirectImportsResult) := do
  requireDocumentVersion p.textDocument
  let doc ← RequestM.readDoc
  checkRequestCancelled
  let inputCtx := Lean.Parser.mkInputContext doc.meta.text.source doc.meta.uri
  let (header, _, _) ← Lean.Parser.parseHeader inputCtx
  let imports :=
    (Lean.Server.collectImports header).foldl (init := #[]) fun acc info =>
      if acc.contains info.module then
        acc
      else
        acc.push info.module
  return RequestTask.pure {
    version := doc.meta.version
    imports
  }

end Beam.LSP.DirectImports
