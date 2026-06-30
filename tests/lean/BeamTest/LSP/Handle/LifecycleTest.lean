/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Handle.Lifecycle

namespace BeamTest.LSP.Handle.LifecycleTest

def main : IO Unit := BeamTest.LSP.Scenario.run BeamTest.LSP.Handle.Lifecycle.run

end BeamTest.LSP.Handle.LifecycleTest

def main := BeamTest.LSP.Handle.LifecycleTest.main
