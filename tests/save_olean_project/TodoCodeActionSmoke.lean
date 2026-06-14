import Lean.Server.CodeActions

open Lean
open Lean.Lsp
open Lean.Server
open Lean.Server.RequestM

@[hole_code_action]
unsafe def todoFixtureHoleAction : Lean.CodeAction.HoleCodeAction :=
  fun _params _snap _ctx hole => do
    let doc ← readDoc
    let some syntaxRange := hole.stx.getRange? (canonicalOnly := true)
      | return #[]
    let lspRange := syntaxRange.toLspRange doc.meta.text
    let edit : TextEdit := { range := lspRange, newText := "0" }
    let action : CodeAction := {
      title := "Replace fixture hole with zero"
      kind? := some "quickfix"
      edit? := WorkspaceEdit.ofTextEdit doc.versionedIdentifier edit
    }
    return #[action]

def todoCodeAction : Nat := _
