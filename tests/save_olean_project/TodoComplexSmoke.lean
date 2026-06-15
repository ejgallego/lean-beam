import Lean.Server.CodeActions

open Lean
open Lean.Lsp
open Lean.Server
open Lean.Server.RequestM

namespace TodoComplex

@[hole_code_action]
unsafe def complexHoleAction : Lean.CodeAction.HoleCodeAction :=
  fun _params _snap _ctx hole => do
    let doc ← readDoc
    let some syntaxRange := hole.stx.getRange? (canonicalOnly := true)
      | return #[]
    let lspRange := syntaxRange.toLspRange doc.meta.text
    let edit : TextEdit := { range := lspRange, newText := "0" }
    let action : CodeAction := {
      title := "Fill complex fixture hole with zero"
      kind? := some "quickfix"
      edit? := WorkspaceEdit.ofTextEdit doc.versionedIdentifier edit
    }
    return #[action]

def textWithSorry : String := "sorry inside a string literal"

-- sorry inside a line comment

/-
sorry inside a block comment, plus /- nested sorry -/
-/

def «sorry» : Nat := 0

section Nested

variable (p : Prop)

def complexHoleTop : Nat := _

def complexHoleNested : Nat :=
  (fun n : Nat => n + _) 2

def complexCodeActionHole : Nat := _

theorem complexSorryOne : True := by
  sorry

theorem complexSorryTwo : True := by
  have h : True := by
    sorry
  exact h

theorem complexIncompleteOne : True := by
  skip

theorem complexIncompleteBranches : And True True := by
  constructor
  · trivial
  · skip

def complexDiagnostic : Nat := "not a Nat"

end Nested

end TodoComplex
