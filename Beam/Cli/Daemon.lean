/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Path
import Beam.Broker.Client
import Beam.Broker.Transport

open Lean

namespace Beam.Cli

open Beam.Broker

structure RegistryEntry where
  daemonId : String
  pid : Nat
  pidNamespace? : Option String := none
  transport : String := "unix"
  port? : Option Nat := none
  socket? : Option String := none
  root : String
  configHash : String
  leanCmd? : Option String := none
  plugin? : Option String := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  clientBin? : Option String := none
  daemonBin? : Option String := none
  bundleId? : Option String := none
  startedAt : String
  requestedPort? : Option Nat := none
  deriving FromJson, ToJson

structure DesiredConfig where
  root : System.FilePath
  leanCmd? : Option String := none
  plugin? : Option System.FilePath := none
  rocqCmd? : Option String := none
  toolchain? : Option String := none
  daemonBin : System.FilePath
  clientBin : System.FilePath
  bundleId : String
  configHash : String
  deriving Repr

def natToPort? (n : Nat) : Option UInt16 :=
  if n < UInt16.size then some n.toUInt16 else none

def registryEndpoint? (entry : RegistryEntry) : Option Transport.Endpoint := do
  match entry.transport with
  | "tcp" => (natToPort? =<< entry.port?).map Transport.Endpoint.tcp
  | "unix" => entry.socket?.map (fun path => Transport.Endpoint.unix (System.FilePath.mk path))
  | _ => none

def endpointFromEntry (entry : RegistryEntry) : IO Transport.Endpoint := do
  match registryEndpoint? entry with
  | some endpoint => pure endpoint
  | none => throw <| IO.userError s!"invalid Beam daemon transport data in registry for {entry.root}"

def endpointSummary (endpoint : Transport.Endpoint) : String :=
  Transport.endpointDescription endpoint

def statsRoot? (resp : Response) : Option String := do
  let result ← resp.result?
  match result.getObjVal? "root" with
  | .ok (.str root) => some root
  | _ => none

def daemonRoot? (endpoint : Transport.Endpoint) : IO (Option String) := do
  try
    let resp ← sendRequest endpoint { op := .stats }
    if resp.ok then
      pure (statsRoot? resp)
    else
      pure none
  catch _ =>
    pure none

def endpointOccupancyError
    (endpoint : Transport.Endpoint)
    (daemonRoot requestedRoot : System.FilePath) : String :=
  s!"selected endpoint {endpointSummary endpoint} already serves Beam root {daemonRoot}, not {requestedRoot}"

def endpointInUseError (endpoint : Transport.Endpoint) : String :=
  s!"selected endpoint {endpointSummary endpoint} is already in use"

def startupFailureSuggestsEndpointInUse (message : String) : Bool :=
  message.contains "address already in use" ||
  message.contains "Address already in use"

def shouldRetryAutomaticStartup
    (usesAutomaticEndpoint : Bool)
    (tries : Nat)
    (endpointOccupied startupAddressInUse : Bool) : Bool :=
  usesAutomaticEndpoint && tries > 0 && (endpointOccupied || startupAddressInUse)

-- A listening TCP port is not enough evidence that it belongs to this project:
-- random auto-port selection can collide with an unrelated Beam daemon.
def daemonServesRoot (endpoint : Transport.Endpoint) (root : System.FilePath) : IO Bool := do
  match ← daemonRoot? endpoint with
  | some daemonRoot => Beam.sameFilePath (System.FilePath.mk daemonRoot) root
  | none => pure false

def endpointAcceptsConnection (endpoint : Transport.Endpoint) : IO Bool := do
  try
    let conn ← Transport.connect endpoint
    Transport.closeConnection conn
    pure true
  catch _ =>
    pure false

end Beam.Cli
