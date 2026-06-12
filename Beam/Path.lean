/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam

/--
Compare two filesystem paths after resolving their canonical spelling.

If either path cannot be resolved, fall back to exact path text equality so callers keep deterministic
behavior for missing paths while handling platform aliases such as macOS `/tmp` and `/private/tmp`
for existing roots.
-/
def sameFilePath (a b : System.FilePath) : IO Bool := do
  try
    pure ((← IO.FS.realPath a).toString == (← IO.FS.realPath b).toString)
  catch _ =>
    pure (a.toString == b.toString)

end Beam
