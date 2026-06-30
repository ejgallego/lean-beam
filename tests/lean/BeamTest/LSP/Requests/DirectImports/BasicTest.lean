/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.DirectImports
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference

namespace BeamTest.LSP.Requests.DirectImports.BasicTest

def checkDirectImports : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"

  let importsReq ← sendDirectImports doc
  let imports : Beam.LSP.DirectImports.DirectImportsResult ← awaitResponseAs importsReq
  if imports.version != 1 then
    throw <| IO.userError s!"directImports: expected version 1, got {imports.version}"
  if imports.imports != #["BeamTest.Fixtures.Deps.DepB"] then
    throw <| IO.userError s!"directImports: unexpected imports {(toJson imports.imports).compress}"

  closeDoc doc

def checkDirectImportsWithStandardLspInterference : ScenarioM Unit := do
  let importsDoc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let importsReq ← sendDirectImports importsDoc
  syncWhitespacePrefixEdit editDoc

  let imports : Beam.LSP.DirectImports.DirectImportsResult ← awaitResponseAs importsReq
  if imports.version != 1 then
    throw <| IO.userError s!"directImports with LSP interference: expected version 1, got {imports.version}"
  if imports.imports != #["BeamTest.Fixtures.Deps.DepB"] then
    throw <| IO.userError
      s!"directImports with LSP interference: unexpected imports {(toJson imports.imports).compress}"

  closeDoc importsDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkDirectImports
  checkDirectImportsWithStandardLspInterference

end BeamTest.LSP.Requests.DirectImports.BasicTest
