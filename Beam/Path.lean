/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam

/-- Resolve a path that must already exist. -/
def resolveExistingPath (path : System.FilePath) : IO System.FilePath :=
  IO.FS.realPath path

/-- Resolve `path`, interpreting relative paths under an already-resolved `root`. -/
def resolvePathAgainstRoot (root path : System.FilePath) : IO System.FilePath :=
  resolveExistingPath <| if path.isAbsolute then path else root / path

/--
Compare two filesystem paths after resolving their canonical spelling.

If either path cannot be resolved, fall back to exact path text equality so callers keep deterministic
behavior for missing paths while handling platform aliases such as macOS `/tmp` and `/private/tmp`
for existing roots.
-/
def sameFilePath (a b : System.FilePath) : IO Bool := do
  try
    pure ((← resolveExistingPath a).toString == (← resolveExistingPath b).toString)
  catch _ =>
    pure (a.toString == b.toString)

/--
Return `path` relative to `root` when the path is exactly the root or is under the root directory.

This is a pure string-level boundary check. Callers that need platform alias or symlink handling
should resolve both paths first with `resolveExistingPath` / `resolvePathAgainstRoot`.
-/
def pathRelativeToRoot? (root path : System.FilePath) : Option String := do
  let rootStr := root.toString
  let pathStr := path.toString
  let rootPrefix := rootStr ++ s!"{System.FilePath.pathSeparator}"
  if pathStr.startsWith rootPrefix then
    some <| (pathStr.drop rootPrefix.length).toString
  else if pathStr == rootStr then
    some "."
  else
    none

/--
Return `path` relative to `root` when possible, otherwise return the original path spelling.
-/
def pathRelativeToRootOrSelf (root path : System.FilePath) : String :=
  (pathRelativeToRoot? root path).getD path.toString

end Beam
