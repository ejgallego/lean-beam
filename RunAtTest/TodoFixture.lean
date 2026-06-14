/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace RunAtTest.TodoFixture

-- Coordinates below track the checked-in files under `tests/save_olean_project`.

def repoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoSmoke.lean"

def codeActionRepoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoCodeActionSmoke.lean"

def brokerPath : String :=
  "TodoSmoke.lean"

def startLine : Nat := 0
def startCharacter : Nat := 0
def endLine : Nat := 17
def endCharacter : Nat := 0

def skippedSorryEndLine : Nat := 12

def sorryLine : Nat := 13
def sorryCharacter : Nat := 2

def sorryPosition : Lean.Lsp.Position := {
  line := sorryLine
  character := sorryCharacter
}

def codeActionLine : Nat := 22
def codeActionStartCharacter : Nat := 28
def codeActionEndCharacter : Nat := 29

def codeActionRange : Lean.Lsp.Range := {
  start := { line := codeActionLine, character := codeActionStartCharacter }
  «end» := { line := codeActionLine, character := codeActionEndCharacter }
}

end RunAtTest.TodoFixture
