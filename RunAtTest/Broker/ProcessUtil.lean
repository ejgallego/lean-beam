/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Protocol
import Beam.Broker.Transport
import RunAtTest.TestHarness

namespace RunAtTest.Broker.TestUtil

abbrev nullBrokerStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .null

def daemonExe : IO System.FilePath := do
  pure <| (← IO.appPath).parent.getD (System.FilePath.mk ".") / "beam-daemon"

def clientExe : IO System.FilePath := do
  pure <| (← IO.appPath).parent.getD (System.FilePath.mk ".") / "beam-client"

private structure ProcessInfo where
  pid : Nat
  ppid : Nat
  state : String
  cmd : String

private def isZombie (proc : ProcessInfo) : Bool :=
  proc.state.contains "Z"

private def listProcesses : IO (Array ProcessInfo) := do
  let out ← IO.Process.output {
    cmd := "ps"
    args := #["-eo", "pid=,ppid=,state=,args="]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to list processes\n{out.stderr}"
  let mut procs := #[]
  for rawLine in out.stdout.split (· == '\n') do
    let parts : List String :=
      (rawLine.trimAscii.toString.split (· == ' ') |>.filterMap fun part =>
        let part := part.trimAscii.toString
        if part.isEmpty then none else some part).toList
    match parts with
    | pidText :: ppidText :: stateText :: cmdParts =>
        match pidText.toNat?, ppidText.toNat? with
        | some pid, some ppid =>
            procs := procs.push {
              pid
              ppid
              state := stateText
              cmd := String.intercalate " " cmdParts
            }
        | _, _ =>
            pure ()
    | _ =>
        pure ()
  pure procs

private def requireUniquePid (label : String) (candidates : Array ProcessInfo) : IO Nat := do
  match candidates.toList with
  | [proc] =>
      pure proc.pid
  | [] =>
      throw <| IO.userError s!"expected one {label} process, found none"
  | _ =>
      throw <| IO.userError s!"expected one {label} process, found {candidates.size}"

private partial def waitForPidGone (pid : Nat) (tries : Nat := 40) : IO Unit := do
  if tries == 0 then
    throw <| IO.userError s!"timed out waiting for pid {pid} to exit"
  let procs ← listProcesses
  if procs.any (fun proc => proc.pid == pid && !isZombie proc) then
    IO.sleep 100
    waitForPidGone pid (tries - 1)
  else
    pure ()

def killLeanServerForEndpoint
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let port ←
    match endpoint with
    | .tcp port => pure port
    | .unix _ => throw <| IO.userError "worker-death helper only supports tcp endpoints"
  let procs ← listProcesses
  let brokerPid ← requireUniquePid "broker daemon" <| procs.filter fun proc =>
    proc.cmd.contains "beam-daemon" &&
      proc.cmd.contains s!"--port {port.toNat}" &&
      proc.cmd.contains s!"--root {root.toString}"
  let serverPid ← requireUniquePid "Lean server" <| procs.filter fun proc =>
    proc.ppid == brokerPid && proc.cmd.contains "--server"
  let out ← IO.Process.output {
    cmd := "kill"
    args := #["-9", toString serverPid]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to kill Lean server pid {serverPid}\n{out.stderr}"
  waitForPidGone serverPid

def spawnLeanBrokerWithPlugin
    (endpoint : Beam.Broker.Endpoint)
    (root leanPlugin : System.FilePath)
    (leanCmd : String := "lean") : IO (IO.Process.Child nullBrokerStdio) := do
  let port ←
    match endpoint with
    | .tcp port => pure port
    | .unix _ => throw <| IO.userError "test Lean broker helpers only support tcp endpoints"
  IO.Process.spawn {
    toStdioConfig := nullBrokerStdio
    cmd := (← daemonExe).toString
    args := #[
      "--port", toString port.toNat,
      "--root", root.toString,
      "--lean-cmd", leanCmd,
      "--lean-plugin", leanPlugin.toString
    ]
    setsid := true
  }

def spawnLeanBroker
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (leanCmd : String := "lean") : IO (IO.Process.Child nullBrokerStdio) := do
  spawnLeanBrokerWithPlugin endpoint root (← RunAtTest.TestHarness.pluginPath) leanCmd

def spawnRocqBroker
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (rocqCmd : String := "coq-lsp") : IO (IO.Process.Child nullBrokerStdio) := do
  let port ←
    match endpoint with
    | .tcp port => pure port
    | .unix _ => throw <| IO.userError "test Rocq broker helpers only support tcp endpoints"
  IO.Process.spawn {
    toStdioConfig := nullBrokerStdio
    cmd := (← daemonExe).toString
    args := #[
      "--port", toString port.toNat,
      "--root", root.toString,
      "--rocq-cmd", rocqCmd
    ]
    setsid := true
  }

partial def waitForBrokerReady
    (endpoint : Beam.Broker.Endpoint)
    (tries : Nat := 50) : IO Unit := do
  try
    let conn ← Beam.Broker.Transport.connect endpoint
    Beam.Broker.Transport.closeConnection conn
  catch _ =>
    if tries == 0 then
      throw <| IO.userError s!"timed out waiting for Beam daemon at {Beam.Broker.Transport.endpointDescription endpoint}"
    IO.sleep 100
    waitForBrokerReady endpoint (tries - 1)

end RunAtTest.Broker.TestUtil
