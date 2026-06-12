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

private def lockPollMs : Nat :=
  100

private def readLockPid? (lockDir : System.FilePath) : IO (Option Nat) := do
  try
    if ← (lockDir / "pid").pathExists then
      let text ← IO.FS.readFile (lockDir / "pid")
      pure <| trimLine text |>.toNat?
    else
      pure none
  catch _ =>
    pure none

private def lockOwnerDescription : Option Nat → String
  | some pid => s!"pid {pid}"
  | none => "unknown owner"

private def lockTimeoutMessage
    (lockDir : System.FilePath)
    (ownerPid? : Option Nat)
    (waitedMs timeoutMs : Nat) : String :=
  s!"timed out after {waitedMs} ms waiting for Beam lock {lockDir}; " ++
    s!"lock owner: {lockOwnerDescription ownerPid?}; timeout: {timeoutMs} ms"

private def removeStaleLock? (lockDir : System.FilePath) (ownerPid? : Option Nat) : IO Bool := do
  match ownerPid? with
  | some ownerPid =>
      if !(← pidAlive ownerPid) then
        if ← lockDir.pathExists then
          IO.FS.removeDirAll lockDir
        pure true
      else
        pure false
  | none =>
      pure false

private partial def acquireLockCore
    (lockDir : System.FilePath)
    (timeoutMs? : Option Nat)
    (waitedMs : Nat := 0) : IO Unit := do
  if let some parent := lockDir.parent then
    IO.FS.createDirAll parent
  let selfPid ← IO.Process.getPID
  try
    IO.FS.createDir lockDir
    IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
  catch _ =>
    let ownerPid? ← readLockPid? lockDir
    if ← removeStaleLock? lockDir ownerPid? then
      acquireLockCore lockDir timeoutMs? waitedMs
    else
      match timeoutMs? with
      | some timeoutMs =>
          if waitedMs >= timeoutMs then
            throw <| IO.userError (lockTimeoutMessage lockDir ownerPid? waitedMs timeoutMs)
      | none =>
          pure ()
      IO.sleep lockPollMs.toUInt32
      acquireLockCore lockDir timeoutMs? (waitedMs + lockPollMs)

def acquireLock (lockDir : System.FilePath) : IO Unit :=
  acquireLockCore lockDir none

/--
Acquire a directory lock, but fail with lock owner diagnostics after `timeoutMs`.

The unbounded `acquireLock` remains available for long-running build/install locks. This bounded
variant is for short project-control critical sections where silent infinite waiting hides daemon
or wrapper failures.
-/
def acquireLockTimeout (lockDir : System.FilePath) (timeoutMs : Nat) : IO Unit :=
  acquireLockCore lockDir (some timeoutMs)

def releaseLock (lockDir : System.FilePath) : IO Unit := do
  if ← lockDir.pathExists then
    IO.FS.removeDirAll lockDir

def withLock (lockDir : System.FilePath) (act : IO α) : IO α := do
  acquireLock lockDir
  try
    act
  finally
    releaseLock lockDir

/-- Run `act` while holding a bounded directory lock. -/
def withLockTimeout (lockDir : System.FilePath) (timeoutMs : Nat) (act : IO α) : IO α := do
  acquireLockTimeout lockDir timeoutMs
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
