/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Handle.Api

namespace BeamTest.LSP.Handle.ApiTest

def main : IO Unit := BeamTest.LSP.Scenario.run BeamTest.LSP.Handle.Api.run

end BeamTest.LSP.Handle.ApiTest

def main := BeamTest.LSP.Handle.ApiTest.main
