/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Workspace.Protocol

open Lean

namespace Beam.Workspace

def addActiveRoot (root : System.FilePath) (json : Json) : Json :=
  json.setObjVal! "active_root" (toJson root.toString)

structure InitError where
  message : String
  activeRoot? : Option System.FilePath := none

instance : ToString InitError where
  toString err := err.message

end Beam.Workspace
