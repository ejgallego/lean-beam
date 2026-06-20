/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.Readiness
import Beam.Broker.RequestArgs
import RunAtTest.Broker.JsonAssert
import Lean

open Lean
open Lean.Lsp
open Beam.Broker
open RunAtTest.Broker.JsonAssert

namespace RunAtTest.Broker.ProtocolTest

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

private def requireResponseResult (label : String) (resp : Response) : IO Json := do
  match resp.result? with
  | some result => pure result
  | none => throw <| IO.userError s!"{label}: expected result payload, got {(toJson resp).compress}"

private def requireErrorData (label : String) (err : Error) : IO Json := do
  match err.data? with
  | some data => pure data
  | none => throw <| IO.userError s!"{label}: expected error data, got {(toJson err).compress}"

private def expectRequestArgError
    (label : String)
    (expectedMessage : String)
    (result : Except Response α) : IO Unit := do
  match result with
  | .ok _ =>
      throw <| IO.userError s!"{label}: expected invalidParams response"
  | .error resp =>
      discard <| requireError label "invalidParams" expectedMessage resp

private def jsonPos (line character : Nat) : Json :=
  Json.mkObj [
    ("line", toJson line),
    ("character", toJson character)
  ]

private def jsonRange (line character endCharacter : Nat) : Json :=
  Json.mkObj [
    ("start", jsonPos line character),
    ("end", jsonPos line endCharacter)
  ]

private def diagnostic (severity : Nat) (message : String) : IO Diagnostic := do
  match fromJson? (α := Diagnostic) <| Json.mkObj [
    ("range", jsonRange 0 0 1),
    ("severity", toJson severity),
    ("message", toJson message)
  ] with
  | .ok diagnostic => pure diagnostic
  | .error err => throw <| IO.userError s!"failed to build diagnostic fixture: {err}"

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

private def checkReadinessBoundary : IO Unit := do
  let uri := "file:///workspace/SaveSmoke/A.lean"
  let clean := decideSyncBarrier uri 7 (some { updates := 1, done := true }) none #[]
  require "clean readiness barrier should be complete" (!clean.incomplete)
  require "clean readiness barrier preserves prior progress"
    (clean.fileProgress? == some { updates := 1, done := true })

  let partialBarrier := decideSyncBarrier uri 7 none (some { updates := 2, done := false }) #[]
  require "partial readiness barrier should be incomplete" partialBarrier.incomplete
  require "partial readiness barrier should explain the incomplete barrier"
    (partialBarrier.message?.any (·.contains "Lean diagnostics barrier did not complete"))

  let incompleteDiagnostic ← diagnostic 3 "Failed to build module dependencies."
  let diagnosticBarrier :=
    decideSyncBarrier uri 7 none (some { updates := 4, done := true }) #[incompleteDiagnostic]
  require "stale dependency diagnostic should force an incomplete barrier" diagnosticBarrier.incomplete
  require "stale dependency diagnostic should force progress done=false"
    (diagnosticBarrier.fileProgress? == some { updates := 4, done := false })

  let hints : Array StaleDirectDepHint := #[{
    module := "SaveSmoke.B"
    path := "SaveSmoke/B.lean"
    needsSave := true
    lastSyncSeq := 4
    lastSaveSeq := 3
  }]
  let incompleteResp :=
    syncBarrierIncompleteResponse uri 7 "SaveSmoke/A.lean" hints #[incompleteDiagnostic]
      diagnosticBarrier.fileProgress?
  let err ← requireError
    "readiness incomplete response"
    syncBarrierIncompleteCode
    (syncBarrierIncompleteMessage uri 7 diagnosticBarrier.fileProgress?)
    incompleteResp
  let data ← requireErrorData "readiness incomplete response" err
  requireJsonString "readiness incomplete response data" "targetPath" "SaveSmoke/A.lean" data
  let completionBlocking ← requireObjVal
    "readiness incomplete response data" "completionBlockingDiagnostics" data
  let completionBlockingItems ← expectOk "readiness completion-blocking diagnostics decode"
    (fromJson? (α := Array SyncBlockingDiagnostic) completionBlocking)
  require "readiness incomplete response should flag completion-blocking diagnostics"
    (completionBlockingItems.any (fun diagnostic =>
      diagnostic.completionBlocking &&
        diagnostic.message.contains "Failed to build module dependencies."))
  let recoveryPlanJson ← requireObjVal "readiness incomplete response data" "recoveryPlan" data
  let recoveryPlan ← expectOk "readiness recovery plan decode"
    (fromJson? (α := Array String) recoveryPlanJson)
  require "readiness recovery plan should start with dependency save"
    (recoveryPlan[0]? == some "lean-beam save \"SaveSmoke/B.lean\"")
  require "readiness recovery plan should include target refresh"
    (recoveryPlan[1]? == some "lean-beam refresh \"SaveSmoke/A.lean\"")
  require "readiness recovery plan should end with lake build"
    (recoveryPlan[2]? == some "lake build")

  let warningDiagnostic ← diagnostic 2 "warning only"
  let successResp := syncFileSuccessResponse 9 #[warningDiagnostic] {
    stateErrorCount := 1
    stateCommandErrorCount := 2
    saveReady := false
    saveReadyReason := "documentErrors"
  } (some { updates := 5, done := true })
  require "readiness success response should be ok" successResp.ok
  require "readiness success response should keep fileProgress"
    (successResp.fileProgress? == some { updates := 5, done := true })
  let successResult ← requireResponseResult "readiness success response" successResp
  requireJsonInt "readiness success payload" "version" 9 successResult
  requireJsonInt "readiness success payload" "warningCount" 1 successResult
  requireJsonInt "readiness success payload" "stateErrorCount" 1 successResult
  requireJsonInt "readiness success payload" "stateCommandErrorCount" 2 successResult
  requireJsonBool "readiness success payload" "saveReady" false successResult
  requireJsonString "readiness success payload" "saveReadyReason" "documentErrors" successResult

  let streamedErrorDiagnostic ← diagnostic 3 "streamed error only"
  let stableCountsResp := syncFileSuccessResponse 10 #[streamedErrorDiagnostic, warningDiagnostic] {
    currentSaveBlockingErrorCount? := some 4
    currentWarningCount? := some 5
    stateErrorCount := 4
    stateCommandErrorCount := 1
    saveReady := false
    saveReadyReason := "documentErrors"
  } none
  let stableCountsResult ← requireResponseResult "readiness stable-count response" stableCountsResp
  requireJsonInt "readiness stable-count payload" "errorCount" 4 stableCountsResult
  requireJsonInt "readiness stable-count payload" "warningCount" 5 stableCountsResult
  requireJsonInt "readiness stable-count payload" "stateErrorCount" 4 stableCountsResult

  let interactiveOnlyResp := syncFileSuccessResponse 11 #[streamedErrorDiagnostic] {
    currentSaveBlockingErrorCount? := some 0
    currentWarningCount? := some 0
    stateErrorCount := 0
    stateCommandErrorCount := 0
    saveReady := true
    saveReadyReason := "ok"
  } none
  let interactiveOnlyResult ← requireResponseResult
    "readiness interactive-only diagnostic response" interactiveOnlyResp
  requireJsonInt "readiness interactive-only payload" "errorCount" 0 interactiveOnlyResult
  requireJsonInt "readiness interactive-only payload" "stateErrorCount" 0 interactiveOnlyResult
  requireJsonBool "readiness interactive-only payload" "saveReady" true interactiveOnlyResult

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
  checkReadinessBoundary
  checkRequestArgsBoundary

end RunAtTest.Broker.ProtocolTest

def main := RunAtTest.Broker.ProtocolTest.main
