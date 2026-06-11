/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Project
import Beam.Workspace

open Lean

namespace Beam.Lean.Workspace

def resolveRoot (rootText : String) : IO (Except Beam.Workspace.InitError System.FilePath) := do
  let rootPath := System.FilePath.mk rootText
  if !rootPath.isAbsolute then
    return .error { message := "workspace root must be an absolute path" }
  try
    let root ← IO.FS.realPath rootPath
    if !(← root.isDir) then
      pure <| .error { message := s!"workspace root is not a directory: {root}" }
    else if !(← Beam.Project.hasLeanProject root) then
      pure <| .error {
        message := s!"workspace root is not a Lean/Lake project: expected lean-toolchain, lakefile.toml, or lakefile.lean in {root}"
      }
    else
      pure <| .ok root
  catch e =>
    pure <| .error { message := s!"workspace root does not resolve: {e.toString}" }

end Beam.Lean.Workspace
