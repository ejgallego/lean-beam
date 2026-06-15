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

def complexRepoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoComplexSmoke.lean"

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

def complexStartLine : Nat := 0
def complexStartCharacter : Nat := 0
def complexEndLine : Nat := 66
def complexEndCharacter : Nat := 0

def complexFalsePositiveStartLine : Nat := 24
def complexFalsePositiveEndLine : Nat := 34

def complexCodeActionLine : Nat := 43
def complexCodeActionStartCharacter : Nat := 35
def complexCodeActionEndCharacter : Nat := 36

def complexSorryStartLine : Nat := 45
def complexSorryEndLine : Nat := 48

def complexIncompleteOneStartLine : Nat := 53
def complexIncompleteOneEndLine : Nat := 56

def complexBranchSkipStartLine : Nat := 59
def complexBranchSkipEndLine : Nat := 60

def complexDiagnosticLine : Nat := 61
def complexDiagnosticEndCharacter : Nat := 42

end RunAtTest.TodoFixture
