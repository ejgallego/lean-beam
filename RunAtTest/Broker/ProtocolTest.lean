/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import Lean

open Lean
open Beam.Broker

namespace RunAtTest.Broker.ProtocolTest

private def requireJsonBool (label field : String) (expected : Bool) (json : Json) : IO Unit := do
  match json.getObjValAs? Bool field with
  | .ok actual =>
      if actual != expected then
        throw <| IO.userError s!"{label}: expected {field}={expected}, got {json.compress}"
  | .error err =>
      throw <| IO.userError s!"{label}: missing or invalid {field}: {err}\n{json.compress}"

private def requireFieldPresent (label field : String) (json : Json) : IO Unit := do
  match json.getObjVal? field with
  | .ok _ => pure ()
  | .error _ =>
      throw <| IO.userError s!"{label}: expected field {field}, got {json.compress}"

private def requireFieldAbsent (label field : String) (json : Json) : IO Unit := do
  match json.getObjVal? field with
  | .ok _ =>
      throw <| IO.userError s!"{label}: unexpected field {field}, got {json.compress}"
  | .error _ => pure ()

private def decodeResponse (label : String) (json : Json) : IO Response := do
  match fromJson? json with
  | .ok resp => pure resp
  | .error err => throw <| IO.userError s!"{label}: failed to decode response: {err}"

private def expectDecodeFailure (label : String) (json : Json) : IO Unit := do
  match fromJson? (α := Response) json with
  | .ok resp =>
      throw <| IO.userError s!"{label}: expected decode failure, got {(toJson resp).compress}"
  | .error _ =>
      pure ()

private def checkResponseJsonShape : IO Unit := do
  let successJson := toJson <| Response.success (Json.mkObj [("value", toJson (1 : Nat))])
  requireJsonBool "success response" "ok" true successJson
  requireFieldPresent "success response" "result" successJson
  requireFieldAbsent "success response" "error" successJson

  let errorJson := toJson <| Response.error "invalidParams" "bad request"
  requireJsonBool "error response" "ok" false errorJson
  requireFieldPresent "error response" "error" errorJson
  requireFieldAbsent "error response" "result" errorJson

private def checkResponseJsonDecode : IO Unit := do
  let legacySuccess ← decodeResponse "legacy success" <| Json.mkObj [
    ("result", Json.mkObj [("value", toJson (1 : Nat))])
  ]
  unless legacySuccess.ok do
    throw <| IO.userError s!"legacy success: expected ok=true, got {(toJson legacySuccess).compress}"

  let legacyError ← decodeResponse "legacy error" <| Json.mkObj [
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  if legacyError.ok then
    throw <| IO.userError s!"legacy error: expected ok=false, got {(toJson legacyError).compress}"

  expectDecodeFailure "error with result" <| Json.mkObj [
    ("ok", toJson false),
    ("result", Json.null),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure "ok with error" <| Json.mkObj [
    ("ok", toJson true),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure "ok=false without error" <| Json.mkObj [
    ("ok", toJson false)
  ]

def main : IO Unit := do
  checkResponseJsonShape
  checkResponseJsonDecode

end RunAtTest.Broker.ProtocolTest

def main := RunAtTest.Broker.ProtocolTest.main
