/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Cli

def trimLine (text : String) : String :=
  text.trimAscii.toString

def readCmdTrim (cmd : String) (args : Array String := #[]) (cwd? : Option System.FilePath := none) : IO String := do
  let out ← IO.Process.output {
    cmd
    args
    cwd := cwd?.map (·.toString)
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"command failed: {cmd} {String.intercalate " " args.toList}\n{out.stderr}"
  pure <| trimLine out.stdout

def commandAvailable (cmd : String) (args : Array String := #["--help"]) : IO Bool := do
  try
    let child ← IO.Process.spawn {
      cmd := cmd
      args := args
      stdin := .null
      stdout := .null
      stderr := .null
    }
    if (← child.tryWait).isNone then
      try
        child.kill
      catch _ =>
        pure ()
      try
        discard <| child.wait
      catch _ =>
        pure ()
    pure true
  catch _ =>
    pure false

def killCommand : IO String := do
  let candidates := [System.FilePath.mk "/bin/kill", System.FilePath.mk "/usr/bin/kill"]
  for candidate in candidates do
    if ← candidate.pathExists then
      return candidate.toString
  if ← commandAvailable "kill" #["-l"] then
    pure "kill"
  else
    throw <| IO.userError "could not find kill command"

def pidAlive (pid : Nat) : IO Bool := do
  let out ← IO.Process.output { cmd := (← killCommand), args := #["-0", toString pid] }
  pure (out.exitCode == 0)

partial def acquireLock (lockDir : System.FilePath) : IO Unit := do
  if let some parent := lockDir.parent then
    IO.FS.createDirAll parent
  let selfPid ← IO.Process.getPID
  try
    IO.FS.createDir lockDir
    IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
  catch _ =>
    let stalePid? ←
      if ← (lockDir / "pid").pathExists then
        let text ← IO.FS.readFile (lockDir / "pid")
        pure <| trimLine text |>.toNat?
      else
        pure none
    if let some stalePid := stalePid? then
      if !(← pidAlive stalePid) then
        if ← lockDir.pathExists then
          IO.FS.removeDirAll lockDir
    IO.sleep 100
    acquireLock lockDir

def releaseLock (lockDir : System.FilePath) : IO Unit := do
  if ← lockDir.pathExists then
    IO.FS.removeDirAll lockDir

def withLock (lockDir : System.FilePath) (act : IO α) : IO α := do
  acquireLock lockDir
  try
    act
  finally
    releaseLock lockDir

def currentPidNamespace? : IO (Option String) := do
  try
    pure <| some (← readCmdTrim "readlink" #["/proc/self/ns/pid"])
  catch _ =>
    pure none

def utcTimestamp : IO String := do
  readCmdTrim "date" #["-u", "+%Y-%m-%dT%H:%M:%SZ"]

end Beam.Cli
