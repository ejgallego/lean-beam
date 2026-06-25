/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Deps
import RunAtTest.Broker.FixtureUtil
import RunAtTest.Broker.JsonAssert

open Beam.Broker
open Lean.Lsp
open RunAtTest.Broker.JsonAssert
open RunAtTest.Broker.TestUtil

namespace RunAtTest.Broker.DepsTest

private def withTempProject (namePrefix : String) (k : System.FilePath → IO α) : IO α := do
  let root ← mkTempProjectRoot namePrefix
  IO.FS.createDirAll root
  try
    k root
  finally
    IO.FS.removeDirAll root

private def writeFile (root : System.FilePath) (relPath text : String) : IO System.FilePath := do
  let path := root / relPath
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path text
  pure path

private def importNames (imports : Array LeanImport) : List String :=
  imports.toList.map (fun imp => (LeanImport.module imp).name)

private def importMapNames (imports : Std.TreeMap String LeanImport) : List String :=
  imports.toList.map Prod.fst

private def requireNames (label : String) (actual expected : List String) : IO Unit :=
  require s!"{label}: expected {expected}, got {actual}" (actual == expected)

private def requireContains (label : String) (actual : List String) (expected : String) : IO Unit :=
  require s!"{label}: expected {actual} to contain {expected}" (actual.contains expected)

private def checkWorkspaceScannerBoundary : IO Unit :=
  withTempProject "beam-deps-scanner" fun root => do
    let a ← writeFile root "A.lean" <| String.intercalate "\n" [
      "import B",
      "import Init",
      "import B",
      "",
      "def a : Nat := b",
      ""
    ]
    discard <| writeFile root "B.lean" <| String.intercalate "\n" [
      "import C",
      "",
      "def b : Nat := c",
      ""
    ]
    discard <| writeFile root "C.lean" "def c : Nat := 1\n"
    discard <| writeFile root "MentionOnly.lean" "-- B appears in text but is not imported\n"
    discard <| writeFile root "BrokenHeader.lean" "import Broken.\n"
    discard <| writeFile root "BrokenMention.lean" "import Broken.\n-- B\n"
    discard <| writeFile root ".lake/Ignored.lean" "import B\n"

    let index ← workspaceModuleIndex root
    require "workspaceModuleIndex includes A" (index.contains "A")
    require "workspaceModuleIndex ignores .lake" (!index.contains ".lake.Ignored")

    let direct ← directWorkspaceImports index a
    requireNames "directWorkspaceImports ignores non-workspace imports and deduplicates"
      (importNames direct) ["B"]

    let state ← mkDepsQueryState root
    let importedByB ← directImportedBy state "B"
    requireNames "directImportedBy ignores mentions and broken non-importers"
      (importNames importedByB) ["A"]

    let closure ← collectImportClosure state "A"
    requireNames "collectImportClosure follows workspace direct imports"
      (importMapNames closure) ["B", "C"]

    let reverseClosure ← collectImportedByClosure state "C"
    let reverseNames := importMapNames reverseClosure
    requireContains "collectImportedByClosure includes direct importer" reverseNames "B"
    requireContains "collectImportedByClosure includes transitive importer" reverseNames "A"

def main : IO Unit := do
  checkWorkspaceScannerBoundary

end RunAtTest.Broker.DepsTest

def main := RunAtTest.Broker.DepsTest.main
