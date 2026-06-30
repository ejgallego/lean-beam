/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Scenario

open BeamTest.LSP.Scenario

namespace BeamTest.LSP.Requests.Interference

def syncWhitespacePrefixEdit (doc : DocHandle) : ScenarioM Unit := do
  changeDoc doc { line := 0, character := 0, delete := "", insert := " " }
  syncDoc doc

end BeamTest.LSP.Requests.Interference
