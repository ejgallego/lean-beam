/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Transport
import Beam.Cli.Args
import Beam.Cli.Daemon
import Beam.Cli.Lock
import Beam.Cli.Project

open Lean

namespace Beam.Cli

open Beam.Broker

def controlDir (root : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv "BEAM_CONTROL_DIR" with
  | some dir =>
      let tag := toString (hash root.toString)
      pure (System.FilePath.mk dir / tag)
  | none =>
      pure (runAtStateDir root)

def registryPath (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "beam-daemon.json")

private def computeConfigHash
    (root : System.FilePath)
    (leanCmd? : Option String)
    (plugin? : Option System.FilePath)
    (rocqCmd? : Option String)
    (daemonBin clientBin : System.FilePath)
    (bundleId : String) : String := Id.run do
  let mut acc : UInt64 := 14695981039346656037
  acc := mixField acc root.toString
  acc := mixField acc (leanCmd?.getD "")
  acc := mixField acc (plugin?.map (·.toString) |>.getD "")
  acc := mixField acc (rocqCmd?.getD "")
  acc := mixField acc daemonBin.toString
  acc := mixField acc clientBin.toString
  acc := mixField acc bundleId
  s!"{acc.toNat}"

private def writeRegistry (root : System.FilePath) (entry : RegistryEntry) : IO Unit := do
  let path ← registryPath root
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  let tmp := path.withExtension "tmp"
  IO.FS.writeFile tmp ((toJson entry).pretty ++ "\n")
  IO.FS.rename tmp path

private def readRegistry? (root : System.FilePath) : IO (Option RegistryEntry) := do
  let path ← registryPath root
  unless ← path.pathExists do
    return none
  try
    let text ← IO.FS.readFile path
    let json ← IO.ofExcept <| Json.parse text
    let entry ← IO.ofExcept <| fromJson? json
    pure (some entry)
  catch _ =>
    pure none

def removeRegistry (root : System.FilePath) : IO Unit := do
  let path ← registryPath root
  if ← path.pathExists then
    IO.FS.removeFile path

def killPid (pid : Nat) : IO Unit := do
  try
    let _ ← IO.Process.output { cmd := (← killCommand), args := #[toString pid] }
    pure ()
  catch _ =>
    pure ()

partial def waitForPidGone (pid : Nat) (tries : Nat := 20) : IO Unit := do
  if tries == 0 then
    pure ()
  else if ← pidAlive pid then
    IO.sleep 100
    waitForPidGone pid (tries - 1)
  else
    pure ()

private def stopDaemonEntry (entry : RegistryEntry) : IO Unit := do
  let mayKillPid ←
    match registryEndpoint? entry with
    | some endpoint =>
        match ← daemonRoot? endpoint with
        | some daemonRoot =>
            if daemonRoot == entry.root then
              try
                let _ ← sendRequest endpoint { op := .shutdown }
                pure ()
              catch _ =>
                pure ()
              pure true
            else
              pure false
        | none =>
            pure true
    | none =>
        pure true
  if mayKillPid && entry.pid > 0 && (← pidAlive entry.pid) then
    killPid entry.pid
    waitForPidGone entry.pid

def stopRegisteredDaemon (root : System.FilePath) : IO Unit := do
  match ← readRegistry? root with
  | none =>
      removeRegistry root
  | some entry =>
      stopDaemonEntry entry
      removeRegistry root

private def requestedPortNat? (opts : CliOptions) : Option Nat :=
  opts.requestedPort?.map (·.toNat)

private def selectPort (opts : CliOptions) : IO UInt16 := do
  match opts.requestedPort? with
  | some port => pure port
  | none =>
      let now ← IO.monoNanosNow
      let seed := now % 20000 + 30000
      if seed < UInt16.size then
        pure seed.toUInt16
      else
        pure 37654

private def selectEndpoint (opts : CliOptions) : IO Transport.Endpoint := do
  match opts.requestedSocket? with
  | some socketPath => pure <| .unix socketPath
  | none => pure <| .tcp (← selectPort opts)

private def usesAutomaticTcpEndpoint (opts : CliOptions) : Bool :=
  opts.requestedSocket?.isNone && opts.requestedPort?.isNone

private partial def selectUnoccupiedEndpoint
    (desired : DesiredConfig)
    (opts : CliOptions)
    (tries : Nat := 10) : IO Transport.Endpoint := do
  let endpoint ← selectEndpoint opts
  match ← daemonRoot? endpoint with
  | none =>
      pure ()
  | some daemonRoot =>
      if usesAutomaticTcpEndpoint opts && tries > 0 then
        return ← selectUnoccupiedEndpoint desired opts (tries - 1)
      else
        throw <| IO.userError (endpointOccupancyError endpoint (System.FilePath.mk daemonRoot) desired.root)
  if ← endpointAcceptsConnection endpoint then
    if usesAutomaticTcpEndpoint opts && tries > 0 then
      return ← selectUnoccupiedEndpoint desired opts (tries - 1)
    else
      throw <| IO.userError (endpointInUseError endpoint)
  else
    pure endpoint

private def daemonStartupLogPath (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "beam-daemon-startup.log")

private def tailLines (text : String) (count : Nat := 20) : String :=
  let lines := text.splitOn "\n"
  let keep := min count lines.length
  String.intercalate "\n" <| lines.drop (lines.length - keep)

def daemonFailureMessage (root : System.FilePath) (detail : String) : IO String := do
  let shouldAppend :=
    detail.contains "Beam daemon connection closed" ||
    detail.contains "no live Beam daemon registered for "
  if !shouldAppend then
    pure detail
  else
    let logPath ← daemonStartupLogPath root
    if ← logPath.pathExists then
      let logText := trimLine (← IO.FS.readFile logPath)
      if logText.isEmpty then
        pure detail
      else
        pure <| detail ++ s!"\nBeam daemon log tail ({logPath}):\n{tailLines logText}"
    else
      pure detail

private def startupFailureMessage (endpoint : Transport.Endpoint) (logPath : System.FilePath) (detail : String) :
    IO String := do
  let msg := if detail.isEmpty then
    s!"failed to start Beam daemon on {endpointSummary endpoint}"
  else
    s!"failed to start Beam daemon on {endpointSummary endpoint}\n{detail}"
  if ← logPath.pathExists then
    let logText := trimLine (← IO.FS.readFile logPath)
    if logText.isEmpty then
      pure msg
    else
      pure <| msg ++ s!"\nstartup log ({logPath}):\n{logText}"
  else
    pure msg

private def startDaemon (desired : DesiredConfig) (endpoint : Transport.Endpoint) (logPath : System.FilePath) :
    IO Nat := do
  let mut args : List String := ["--root", desired.root.toString]
  match endpoint with
  | .tcp port =>
      args := args ++ ["--port", toString port.toNat]
  | .unix socket =>
      args := args ++ ["--socket", socket.toString]
  if let some leanCmd := desired.leanCmd? then
    args := args ++ ["--lean-cmd", leanCmd]
  if let some plugin := desired.plugin? then
    args := args ++ ["--lean-plugin", plugin.toString]
  if let some rocqCmd := desired.rocqCmd? then
    args := args ++ ["--rocq-cmd", rocqCmd]
  if let some parent := logPath.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile logPath ""
  let cmd := String.intercalate " " ((desired.daemonBin.toString :: args).map shellQuote)
  let shell := s!"exec {cmd} >{shellQuote logPath.toString} 2>&1 < /dev/null"
  let child ← IO.Process.spawn {
    cmd := "sh"
    args := #["-c", shell]
    cwd := some desired.root
    stdin := .null
    stdout := .null
    stderr := .null
  }
  let pid := child.pid.toNat
  pure pid

private partial def waitForDaemon
    (pid : Nat)
    (endpoint : Transport.Endpoint)
    (logPath : System.FilePath)
    (root : System.FilePath)
    (tries : Nat := 300) : IO Unit := do
  match ← daemonRoot? endpoint with
  | some daemonRoot =>
      if daemonRoot == root.toString then
        pure ()
      else
        throw <| IO.userError (endpointOccupancyError endpoint (System.FilePath.mk daemonRoot) root)
  | none =>
      if !(← pidAlive pid) then
        throw <| IO.userError (← startupFailureMessage endpoint logPath "Beam daemon process exited before responding")
      else if tries == 0 then
        throw <| IO.userError (← startupFailureMessage endpoint logPath "Beam daemon did not become ready before timeout")
      else
        IO.sleep 100
        waitForDaemon pid endpoint logPath root (tries - 1)

private def registryEntryFor (desired : DesiredConfig) (pid : Nat) (endpoint : Transport.Endpoint) (opts : CliOptions) :
    IO RegistryEntry := do
  let (transport, port?, socket?) :=
    match endpoint with
    | .tcp port => ("tcp", some port.toNat, none)
    | .unix path => ("unix", none, some path.toString)
  pure {
    daemonId := s!"{desired.configHash.take 12}-{pid}"
    pid
    pidNamespace? := ← currentPidNamespace?
    transport
    port?
    socket?
    root := desired.root.toString
    configHash := desired.configHash
    leanCmd? := desired.leanCmd?
    plugin? := desired.plugin?.map (·.toString)
    rocqCmd? := desired.rocqCmd?
    toolchain? := desired.toolchain?
    clientBin? := some desired.clientBin.toString
    daemonBin? := some desired.daemonBin.toString
    bundleId? := some desired.bundleId
    startedAt := ← utcTimestamp
    requestedPort? := requestedPortNat? opts
  }

private partial def startDaemonEntry
    (desired : DesiredConfig)
    (opts : CliOptions)
    (tries : Nat := 10) : IO (Transport.Endpoint × RegistryEntry) := do
  let endpoint ← selectUnoccupiedEndpoint desired opts
  let logPath ← daemonStartupLogPath desired.root
  let pid ← startDaemon desired endpoint logPath
  try
    waitForDaemon pid endpoint logPath desired.root
  catch err =>
    if pid > 0 && (← pidAlive pid) then
      killPid pid
      waitForPidGone pid
    if shouldRetryAutomaticStartup (usesAutomaticTcpEndpoint opts) tries (← endpointAcceptsConnection endpoint) then
      return ← startDaemonEntry desired opts (tries - 1)
    throw err
  let entry ← registryEntryFor desired pid endpoint opts
  pure (endpoint, entry)

def desiredConfig (home root : System.FilePath) (required : Backend) : IO DesiredConfig := do
  let defaultPaths ← defaultBundlePaths home
  let mut daemonBin := defaultPaths.daemon
  let mut clientBin := defaultPaths.client
  let mut plugin? : Option System.FilePath := none
  let mut leanCmd? : Option String := none
  let mut rocqCmd? : Option String := none
  let mut toolchain? : Option String := none
  let mut bundleId := "default"
  match required with
  | .lean =>
      if ← hasLeanProject root then
        let toolchain ← leanToolchain root
        let (bundle, id) ← ensureToolchainBundle root home toolchain
        ensureLeanBundleExists bundle
        daemonBin := bundle.daemon
        clientBin := bundle.client
        plugin? := some bundle.plugin
        leanCmd? := some (← leanBin root)
        toolchain? := some toolchain
        bundleId := id
      else
        throw <| IO.userError s!"could not resolve Lean Beam daemon config for {root}"
  | .rocq =>
      let helpers ← ensureDefaultDaemonHelpers home
      daemonBin := helpers.daemon
      clientBin := helpers.client
  if ← hasRocqProject root then
    rocqCmd? ← maybeRocqCmd root
  else if required == .rocq then
    rocqCmd? := some (← rocqCmd root)
  match required with
  | .lean =>
      if leanCmd?.isNone || plugin?.isNone then
        throw <| IO.userError s!"could not resolve Lean Beam daemon config for {root}"
  | .rocq =>
      if rocqCmd?.isNone then
        throw <| IO.userError s!"could not resolve Rocq Beam daemon config for {root}"
  let configHash := computeConfigHash root leanCmd? plugin? rocqCmd? daemonBin clientBin bundleId
  pure {
    root
    leanCmd?
    plugin?
    rocqCmd?
    toolchain?
    daemonBin
    clientBin
    bundleId
    configHash
  }

def registryLiveFor (root : System.FilePath) (expectedHash? : Option String := none) : IO (Option RegistryEntry) := do
  match ← readRegistry? root with
  | none => pure none
  | some entry =>
      let rootOk := entry.root == root.toString
      let hashOk := expectedHash?.map (· == entry.configHash) |>.getD true
      if !rootOk || !hashOk then
        pure none
      else if let some endpoint := registryEndpoint? entry then
        -- In PID-isolated sandboxes, the recorded daemon pid can be meaningless outside
        -- the namespace that started it. Prefer a root-matching endpoint over pid probes.
        if ← daemonServesRoot endpoint root then
          pure (some entry)
        else if entry.pid == 0 || !(← pidAlive entry.pid) then
          pure none
        else
          pure none
      else if entry.pid == 0 || !(← pidAlive entry.pid) then
        pure none
      else
        pure none

structure EnsuredProjectDaemon where
  endpoint : Transport.Endpoint
  startedNew : Bool := false

def ensureProjectDaemon (home root : System.FilePath) (backend : Backend) (opts : CliOptions) :
    IO EnsuredProjectDaemon := do
  let desired ← desiredConfig home root backend
  let lockDir ← controlDir root
  let lockDir := lockDir / "lock"
  withLock lockDir do
    if let some live ← registryLiveFor root desired.configHash then
      if let some endpoint := registryEndpoint? live then
        return { endpoint, startedNew := false }
      removeRegistry root
    let live? ← registryLiveFor root
    if live?.isNone then
      removeRegistry root
    let (endpoint, entry) ← startDaemonEntry desired opts
    writeRegistry root entry
    if let some live := live? then
      unless live.pid == entry.pid &&
          live.transport == entry.transport &&
          live.port? == entry.port? &&
          live.socket? == entry.socket? do
        stopDaemonEntry live
    pure { endpoint, startedNew := true }

private structure WrapperLease where
  root : System.FilePath
  path : System.FilePath

private structure WrapperLeaseMetadata where
  pid : Nat
  pidNamespace? : Option String := none
  createdAt : String
  deriving FromJson, ToJson

private def wrapperLeaseDir (root : System.FilePath) : IO System.FilePath := do
  pure ((← controlDir root) / "wrapper-leases")

private def removeWrapperLeasePath (path : System.FilePath) : IO Unit := do
  try
    if ← path.pathExists then
      IO.FS.removeFile path
  catch _ =>
    pure ()

private def acquireWrapperLease (root : System.FilePath) : IO WrapperLease := do
  let dir ← wrapperLeaseDir root
  IO.FS.createDirAll dir
  let pid ← IO.Process.getPID
  let stamp ← IO.monoNanosNow
  let path := dir / s!"{stamp}-{pid}.lease"
  let tmp := dir / s!"{stamp}-{pid}.lease.tmp"
  let metadata : WrapperLeaseMetadata := {
    pid := pid.toNat
    pidNamespace? := ← currentPidNamespace?
    createdAt := ← utcTimestamp
  }
  IO.FS.writeFile tmp ((toJson metadata).pretty ++ "\n")
  IO.FS.rename tmp path
  pure { root, path }

private def releaseWrapperLease (lease : WrapperLease) : IO Unit := do
  removeWrapperLeasePath lease.path

private def readWrapperLeaseMetadata? (path : System.FilePath) : IO (Option WrapperLeaseMetadata) := do
  try
    let text ← IO.FS.readFile path
    let json ← IO.ofExcept <| Json.parse text
    let metadata ← IO.ofExcept <| fromJson? json
    pure (some metadata)
  catch _ =>
    pure none

private def staleWrapperLease? (currentNamespace? : Option String) (path : System.FilePath) :
    IO Bool := do
  match ← readWrapperLeaseMetadata? path with
  | none => pure false
  | some metadata =>
      if metadata.pid == 0 then
        pure true
      else if metadata.pidNamespace? == currentNamespace? then
        pure (!(← pidAlive metadata.pid))
      else
        -- The PID may be meaningful only inside a different sandbox namespace.
        pure false

private def activeOtherWrapperLeases (lease : WrapperLease) : IO (Array IO.FS.DirEntry) := do
  let dir ← wrapperLeaseDir lease.root
  unless ← dir.pathExists do
    return #[]
  let currentNamespace? ← currentPidNamespace?
  let entries ← dir.readDir
  let mut active := #[]
  for entry in entries do
    if entry.path != lease.path && entry.fileName.endsWith ".lease" then
      if ← staleWrapperLease? currentNamespace? entry.path then
        removeWrapperLeasePath entry.path
      else
        active := active.push entry
  pure active

private partial def waitForOtherWrapperLeases (lease : WrapperLease) (tries : Nat := 600) : IO Unit := do
  let others ← activeOtherWrapperLeases lease
  if others.isEmpty then
    pure ()
  else if tries == 0 then
    pure ()
  else
    IO.sleep 50
    waitForOtherWrapperLeases lease (tries - 1)

def withWrapperLease (root : System.FilePath) (startedNew : Bool) (act : IO α) : IO α := do
  let lease ← acquireWrapperLease root
  let result ←
    try
      pure <| Except.ok (← act)
    catch err =>
      pure <| Except.error err
  if startedNew then
    -- The wrapper invocation that started the daemon must not exit early while sibling
    -- wrapper requests for the same root are still in flight, or its sandbox can kill the daemon.
    waitForOtherWrapperLeases lease
  releaseWrapperLease lease
  match result with
  | .ok value => pure value
  | .error err => throw err

def lookupProjectDaemon (root : System.FilePath) : IO RegistryEntry := do
  let lockDir ← controlDir root
  let lockDir := lockDir / "lock"
  withLock lockDir do
    match ← registryLiveFor root with
    | some entry => pure entry
    | none =>
        stopRegisteredDaemon root
        throw <| IO.userError (← daemonFailureMessage root s!"no live Beam daemon registered for {root}")

end Beam.Cli
