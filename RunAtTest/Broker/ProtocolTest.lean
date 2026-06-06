/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.RequestArgs
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

private def requireError
    (label : String)
    (expectedCode : String)
    (expectedMessage : String)
    (resp : Response) : IO Error := do
  if resp.ok then
    throw <| IO.userError s!"{label}: expected error response, got {(toJson resp).compress}"
  match resp.error? with
  | some err =>
      if err.code != expectedCode then
        throw <| IO.userError s!"{label}: expected code={expectedCode}, got {(toJson resp).compress}"
      if err.message != expectedMessage then
        throw <| IO.userError s!"{label}: expected message={expectedMessage}, got {(toJson resp).compress}"
      pure err
  | none =>
      throw <| IO.userError s!"{label}: expected error payload, got {(toJson resp).compress}"

private def expectRequestArgError
    (label : String)
    (expectedMessage : String)
    (result : Except Response α) : IO Unit := do
  match result with
  | .ok _ =>
      throw <| IO.userError s!"{label}: expected invalidParams response"
  | .error resp =>
      discard <| requireError label "invalidParams" expectedMessage resp

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

private def checkBrokerFailureRoundTrip : IO Unit := do
  let data := Json.mkObj [("uri", toJson "file:///A.lean")]
  let failure : BrokerFailure := {
    code := .contentModified
    message := "file changed"
    data? := some data
  }
  match decodeBrokerFailure? (brokerFailureMessage failure) with
  | some decoded =>
      if decoded.code != failure.code || decoded.message != failure.message then
        throw <| IO.userError s!"broker failure round trip: got {(toJson decoded).compress}"
  | none =>
      throw <| IO.userError "broker failure round trip: failed to decode encoded failure"

  let err ← requireError "broker failure response" "contentModified" "file changed" <|
    responseForExceptionMessage (brokerFailureMessage failure)
  match err.data? with
  | some actual =>
      if actual.compress != data.compress then
        throw <| IO.userError s!"broker failure response: expected data {data.compress}, got {actual.compress}"
  | none =>
      throw <| IO.userError "broker failure response: expected error data"

private def checkExceptionErrorMapping : IO Unit := do
  discard <| requireError
    "request cancellation exception"
    "requestCancelled"
    "requestCancelled: client cancelled request"
    (responseForExceptionMessage "requestCancelled: client cancelled request")
  discard <| requireError
    "sync barrier exception"
    syncBarrierIncompleteCode
    "Lean diagnostics barrier did not complete for /tmp/A.lean"
    (responseForExceptionMessage "Lean diagnostics barrier did not complete for /tmp/A.lean")
  discard <| requireError
    "save target exception"
    saveTargetNotModuleCode
    "could not resolve a Lake module for /tmp/A.lean"
    (responseForExceptionMessage "could not resolve a Lake module for /tmp/A.lean")
  discard <| requireError
    "unknown exception"
    "internalError"
    "some backend failure"
    (responseForExceptionMessage "some backend failure")

private def checkJsonRpcErrorMapping : IO Unit := do
  discard <| requireError
    "jsonrpc known error"
    "invalidParams"
    "bad params"
    (responseForExceptionMessage "jsonrpcerr:{\"code\":-32602,\"message\":\"bad params\"}")
  discard <| requireError
    "embedded jsonrpc error"
    "-32803"
    "focused goal error"
    (responseForExceptionMessage
      "Cannot read LSP message: JSON '{\"error\":{\"code\":-32803,\"message\":\"focused goal error\"}}' did not have the format of a JSON-RPC message.")

private def checkRequestArgsBoundary : IO Unit := do
  let runAtMissingText : Request := {
    op := .runAt
    path? := some "Demo.lean"
    line? := some 1
    character? := some 2
  }
  expectRequestArgError "run_at args missing text" "missing 'text'" runAtMissingText.runAtArgs

  let runAtRocqUnsupported : Request := {
    op := .runAt
    backend := .rocq
    path? := some "Demo.v"
    line? := some 1
    character? := some 2
    text? := some "Check nat."
  }
  expectRequestArgError
    "rocq run_at args"
    "rocq backend does not support run_at yet"
    runAtRocqUnsupported.runAtArgs

  let requestAtBadPositionParam : Request := {
    op := .requestAt
    path? := some "Demo.lean"
    line? := some 1
    character? := some 2
    method? := some "textDocument/hover"
    params? := some <| Json.mkObj [("position", Json.null)]
  }
  expectRequestArgError
    "request_at args position override"
    "'params' must not include 'position'; request_at injects it from <line>/<character>"
    requestAtBadPositionParam.requestAtArgs

def main : IO Unit := do
  checkResponseJsonShape
  checkResponseJsonDecode
  checkBrokerFailureRoundTrip
  checkExceptionErrorMapping
  checkJsonRpcErrorMapping
  checkRequestArgsBoundary

end RunAtTest.Broker.ProtocolTest

def main := RunAtTest.Broker.ProtocolTest.main
