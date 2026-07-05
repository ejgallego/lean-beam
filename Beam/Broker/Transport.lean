/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
-- `Std.Internal.Async.TCP` moved to `Std.Async.TCP` in Lean v4.31. Use the lower-level UV
-- socket API because it is available across the supported toolchain range.
import Std.Internal.UV.TCP
import Std.Net.Addr

open Lean

namespace Beam.Broker.Transport

open Std.Net
open Std.Internal.UV

inductive Endpoint where
  | tcp (port : UInt16)
  deriving Repr, BEq

inductive Connection where
  | tcp (client : TCP.Socket)

inductive Listener where
  | tcp (server : TCP.Socket)

def localhost (port : UInt16) : SocketAddress :=
  SocketAddressV4.mk (.ofParts 127 0 0 1) port

def endpointDescription : Endpoint → String
  | .tcp port => s!"tcp://127.0.0.1:{port.toNat}"

private def waitTcpPromise (promise : IO.Promise (Except IO.Error α)) (failureMessage : String) :
    IO α := do
  let some result := promise.result?.get
    | throw <| IO.userError failureMessage
  match result with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{failureMessage}: {err}"

def connect (endpoint : Endpoint) : IO Connection := do
  match endpoint with
  | .tcp port =>
      let addr := localhost port
      let client ← TCP.Socket.new
      let promise ← TCP.Socket.connect client addr
      waitTcpPromise promise "Beam daemon connection failed before TCP connect completed"
      pure <| .tcp client

def bindAndListen (endpoint : Endpoint) (backlog : UInt32 := 16) : IO Listener := do
  match endpoint with
  | .tcp port =>
      let server ← TCP.Socket.new
      TCP.Socket.bind server (localhost port)
      TCP.Socket.listen server backlog
      pure <| .tcp server

def accept (listener : Listener) : IO Connection := do
  match listener with
  | .tcp server =>
      let promise ← TCP.Socket.accept server
      pure <| .tcp (← waitTcpPromise promise "Beam daemon listener closed before TCP accept completed")

def closeConnection (conn : Connection) : IO Unit := do
  match conn with
  | .tcp client =>
      try
        let promise ← TCP.Socket.shutdown client
        waitTcpPromise promise "Beam daemon connection closed before TCP shutdown completed"
      catch _ =>
        pure ()

def closeListener (listener : Listener) : IO Unit := do
  match listener with
  | .tcp _ =>
      pure ()

private def sendMsgTcp (client : TCP.Socket) (msg : String) : IO Unit := do
  let bytes := msg.toUTF8
  let header := s!"{bytes.size}\n".toUTF8
  let promise ← TCP.Socket.send client #[header, bytes]
  waitTcpPromise promise "Beam daemon connection closed before TCP send completed"

private def recvMsgTcp (client : TCP.Socket) : IO String := do
  let mut header := ByteArray.empty
  repeat
    let promise ← TCP.Socket.recv? client 1
    let some chunk ← waitTcpPromise promise "Beam daemon connection closed during TCP receive"
      | throw <| IO.userError "Beam daemon connection closed"
    if chunk[0]! == '\n'.toUInt8 then
      break
    header := header ++ chunk
  let some lenStr := String.fromUTF8? header
    | throw <| IO.userError "invalid Beam daemon header"
  let some len := lenStr.toNat?
    | throw <| IO.userError "invalid Beam daemon length"
  let mut payload := ByteArray.empty
  while payload.size < len do
    let promise ← TCP.Socket.recv? client (len - payload.size).toUInt64
    let some chunk ← waitTcpPromise promise "Beam daemon connection closed during TCP receive"
      | throw <| IO.userError "Beam daemon connection closed"
    payload := payload ++ chunk
  let some msg := String.fromUTF8? payload
    | throw <| IO.userError "invalid Beam daemon UTF-8"
  pure msg

def sendMsg (conn : Connection) (msg : String) : IO Unit := do
  match conn with
  | .tcp client => sendMsgTcp client msg

def recvMsg (conn : Connection) : IO String := do
  match conn with
  | .tcp client => recvMsgTcp client

end Beam.Broker.Transport
