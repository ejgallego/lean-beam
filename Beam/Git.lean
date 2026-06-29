/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Git

/--
Run `git -C dir ...` and return trimmed stdout on success.

This is for best-effort local metadata probes. Missing Git, non-Git directories,
and failing commands all return `none`.
-/
def runTrimmed? (dir : System.FilePath) (args : Array String) : IO (Option String) := do
  try
    let out ← IO.Process.output {
      cmd := "git"
      args := #["-C", dir.toString] ++ args
    }
    if out.exitCode == 0 then
      let text := out.stdout.trimAscii.toString
      if text.isEmpty then
        pure none
      else
        pure (some text)
    else
      pure none
  catch _ =>
    pure none

def fullCommitAt? (dir : System.FilePath) : IO (Option String) :=
  runTrimmed? dir #["rev-parse", "HEAD"]

def branchAt? (dir : System.FilePath) : IO (Option String) := do
  match ← runTrimmed? dir #["rev-parse", "--abbrev-ref", "HEAD"] with
  | some "HEAD" => pure none
  | branch? => pure branch?

def dirtyAt? (dir : System.FilePath) : IO (Option Bool) := do
  try
    let out ← IO.Process.output {
      cmd := "git"
      args := #["-C", dir.toString, "status", "--short"]
    }
    if out.exitCode == 0 then
      pure (some !out.stdout.trimAscii.isEmpty)
    else
      pure none
  catch _ =>
    pure none

end Beam.Git
