/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Workspace.Protocol

open Lean

namespace Beam.Workspace

def addWorkspaceDescriptor (root : System.FilePath) (json : Json) : Json :=
  json.setObjVal! "workspace" (toJson <| Descriptor.ofRoot root)

structure InitError where
  message : String

instance : ToString InitError where
  toString err := err.message

end Beam.Workspace
