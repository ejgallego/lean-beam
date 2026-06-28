/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.Readiness
import Beam.Broker.RequestArgs
import Beam.JsonPretty
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

private def expectSyncFileResultDecodeFailure (label : String) (json : Json) : IO Unit := do
  match fromJson? (α := SyncFileResult) json with
  | .ok result =>
      throw <| IO.userError s!"{label}: expected decode failure, got {(toJson result).compress}"
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

private def lspPos (line character : Nat) : Lsp.Position :=
  { line, character }

private def lspRange (line character endCharacter : Nat) : Lsp.Range :=
  { start := lspPos line character, «end» := lspPos line endCharacter }

private def diagnostic (severity : DiagnosticSeverity) (message : String) : Diagnostic :=
  let range := lspRange 0 0 1
  {
    range
    fullRange? := some range
    severity? := some severity
    message
  }

private def syncSummaryFor
    (version : Nat)
    (saveReady : Bool := true)
    (saveReadyReason : String := "ok")
    (warningCount : Nat := 0) : SyncSummary := {
  currentVersion := version
  readiness := {
    current := {
      warningCount
      saveReady
      saveReadyReason
    }
  }
}

private def syncDiagnosticCountsJson : Json :=
  Json.mkObj [
    ("error", toJson (0 : Nat)),
    ("warning", toJson (0 : Nat)),
    ("information", toJson (0 : Nat)),
    ("hint", toJson (0 : Nat)),
    ("unknown", toJson (0 : Nat)),
    ("total", toJson (0 : Nat))
  ]

private def syncReadinessCurrentJson (saveReady : Bool := true) : Json :=
  Json.mkObj [
    ("errorCount", toJson (0 : Nat)),
    ("warningCount", toJson (0 : Nat)),
    ("saveReady", toJson saveReady),
    ("saveReadyReason", toJson "ok"),
    ("blockingDiagnostics", toJson (#[] : Array SyncBlockingDiagnostic)),
    ("blockingCommandMessages", toJson (#[] : Array SyncBlockingCommandMessage))
  ]

private def syncSummaryJson (version : Nat) (readinessCurrent : Json) : Json :=
  Json.mkObj [
    ("currentVersion", toJson version),
    ("diagnostics", Json.mkObj [("current", syncDiagnosticCountsJson)]),
    ("readiness", Json.mkObj [("current", readinessCurrent)])
  ]

private def syncFileResultJson (version : Nat) (summary : Json) : Json :=
  Json.mkObj [
    ("version", toJson version),
    ("syncSummary", summary)
  ]

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
  let success ← decodeResponse "success" <| Json.mkObj [
    ("ok", toJson true),
    ("result", Json.mkObj [("value", toJson (1 : Nat))])
  ]
  unless success.ok do
    throw <| IO.userError s!"success: expected ok=true, got {(toJson success).compress}"

  let error ← decodeResponse "error" <| Json.mkObj [
    ("ok", toJson false),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  if error.ok then
    throw <| IO.userError s!"error: expected ok=false, got {(toJson error).compress}"

  expectDecodeFailure "missing ok success" <| Json.mkObj [
    ("result", Json.mkObj [("value", toJson (1 : Nat))])
  ]
  expectDecodeFailure "missing ok error" <| Json.mkObj [
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
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

private def checkOrderedJsonPretty : IO Unit := do
  let summary : SyncSummary := {
    currentVersion := 3
    diagnostics := { current := {} }
    readiness := { current := {} }
  }
  let resp : Response := {
    ok := true
    result? := some <| toJson <| SyncFileResult.ofSummary summary
    fileProgress? := some {
      updates := 2
      done := true
      line? := some 1
      totalLines? := some 1
    }
  }
  let json := toJson resp
  let rendered := Beam.orderedJsonPretty json
  let expected := String.intercalate "\n" [
    "{",
    "  \"ok\": true,",
    "  \"result\": {",
    "    \"version\": 3,",
    "    \"syncSummary\": {",
    "      \"currentVersion\": 3,",
    "      \"readiness\": {",
    "        \"current\": {",
    "          \"saveReady\": true,",
    "          \"errorCount\": 0,",
    "          \"warningCount\": 0,",
    "          \"saveReadyReason\": \"ok\",",
    "          \"blockingDiagnostics\": [],",
    "          \"blockingCommandMessages\": []",
    "        }",
    "      },",
    "      \"diagnostics\": {",
    "        \"current\": {",
    "          \"error\": 0,",
    "          \"warning\": 0,",
    "          \"information\": 0,",
    "          \"hint\": 0,",
    "          \"unknown\": 0,",
    "          \"total\": 0",
    "        }",
    "      }",
    "    }",
    "  },",
    "  \"fileProgress\": {",
    "    \"done\": true,",
    "    \"updates\": 2,",
    "    \"line\": 1,",
    "    \"totalLines\": 1",
    "  }",
    "}"
  ]
  if rendered != expected then
    throw <| IO.userError s!"ordered JSON pretty output changed:\n{rendered}"
  let parsed ← expectOk "ordered JSON pretty parse" (Json.parse rendered)
  require "ordered JSON pretty output should round-trip" (parsed.compress == json.compress)

private def checkSyncFileResultDecode : IO Unit := do
  let valid := syncFileResultJson 7 (syncSummaryJson 7 (syncReadinessCurrentJson true))
  discard <| IO.ofExcept <| fromJson? (α := SyncFileResult) valid
  for field in #[
    "saveReady",
    "errorCount",
    "warningCount",
    "saveReadyReason",
    "blockingDiagnostics",
    "blockingCommandMessages",
    "stateErrorCount",
    "stateCommandErrorCount"
  ] do
    expectSyncFileResultDecodeFailure s!"sync result removed top-level field {field}" <|
      valid.setObjVal! field Json.null
  expectSyncFileResultDecodeFailure "sync result version mismatch" <|
    syncFileResultJson 8 (syncSummaryJson 7 (syncReadinessCurrentJson true))
  let incompleteReadiness := Json.mkObj [
    ("errorCount", toJson (0 : Nat)),
    ("warningCount", toJson (0 : Nat)),
    ("saveReadyReason", toJson "ok"),
    ("blockingDiagnostics", toJson (#[] : Array SyncBlockingDiagnostic)),
    ("blockingCommandMessages", toJson (#[] : Array SyncBlockingCommandMessage))
  ]
  expectSyncFileResultDecodeFailure "sync result missing nested saveReady" <|
    syncFileResultJson 7 (syncSummaryJson 7 incompleteReadiness)

private def checkBrokerFailureResponse : IO Unit := do
  let data := Json.mkObj [("uri", toJson "file:///A.lean")]
  let failure : BrokerFailure := {
    code := .contentModified
    message := "file changed"
    data? := some data
  }
  let err ← requireError "broker failure response" "contentModified" "file changed" <|
    failure.toResponse
  match err.data? with
  | some actual =>
      if actual.compress != data.compress then
        throw <| IO.userError s!"broker failure response: expected data {data.compress}, got {actual.compress}"
  | none =>
      throw <| IO.userError "broker failure response: expected error data"

private def checkJsonRpcErrorObjectMapping : IO Unit := do
  discard <| requireError
    "jsonrpc known numeric error"
    "invalidParams"
    "bad params"
    (responseForJsonRpcErrorObject <| Json.mkObj [
      ("code", toJson (-32602 : Int)),
      ("message", toJson "bad params")
    ])
  discard <| requireError
    "jsonrpc string error"
    "-32803"
    "focused goal error"
    (responseForJsonRpcErrorObject <| Json.mkObj [
      ("code", toJson "-32803"),
      ("message", toJson "focused goal error")
    ])

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

  let incompleteDiagnostic := diagnostic .information "Failed to build module dependencies."
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

  let successResp := syncFileSuccessResponse
    (syncSummaryFor 9 (saveReady := false) (saveReadyReason := "documentErrors"))
    (some { updates := 5, done := true })
  require "readiness success response should be ok" successResp.ok
  require "readiness success response should keep fileProgress"
    (successResp.fileProgress? == some { updates := 5, done := true })
  let successResult ← requireResponseResult "readiness success response" successResp
  requireJsonInt "readiness success payload" "version" 9 successResult
  requireFieldAbsent "readiness success payload" "warningCount" successResult
  requireFieldAbsent "readiness success payload" "stateErrorCount" successResult
  requireFieldAbsent "readiness success payload" "stateCommandErrorCount" successResult
  requireFieldAbsent "readiness success payload" "blockingDiagnostics" successResult
  requireFieldAbsent "readiness success payload" "blockingCommandMessages" successResult
  requireFieldAbsent "readiness success payload" "saveReady" successResult
  requireFieldAbsent "readiness success payload" "saveReadyReason" successResult
  let successSyncResult ← expectOk "readiness success payload decode" <|
    fromJson? (α := SyncFileResult) successResult
  require "readiness success payload nested saveReady"
    (!successSyncResult.currentReadiness.saveReady)

  let streamedErrorDiagnostic := diagnostic .error "streamed error only"
  let stableCountsResp := syncFileSuccessResponse
    (syncSummaryFor 10 (saveReady := false) (saveReadyReason := "documentErrors") (warningCount := 5))
    none
  let stableCountsResult ← requireResponseResult "readiness stable-count response" stableCountsResp
  requireFieldAbsent "readiness stable-count payload" "errorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "warningCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "stateErrorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "stateCommandErrorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "blockingDiagnostics" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "blockingCommandMessages" stableCountsResult

  if syncErrorCount #[streamedErrorDiagnostic] != 1 then
    throw <| IO.userError
      s!"readiness diagnostic fixture should count as an error, got {syncErrorCount #[streamedErrorDiagnostic]}"

  let interactiveOnlyResp := syncFileSuccessResponse (syncSummaryFor 11) none
  let interactiveOnlyResult ← requireResponseResult
    "readiness interactive-only diagnostic response" interactiveOnlyResp
  requireFieldAbsent "readiness interactive-only payload" "errorCount" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "stateErrorCount" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "stateCommandErrorCount"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "blockingDiagnostics"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "blockingCommandMessages"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "saveReady" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "saveReadyReason"
    interactiveOnlyResult
  let interactiveOnlySyncResult ← expectOk "readiness interactive-only payload decode" <|
    fromJson? (α := SyncFileResult) interactiveOnlyResult
  require "readiness interactive-only payload nested saveReady"
    interactiveOnlySyncResult.currentReadiness.saveReady

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
  checkOrderedJsonPretty
  checkSyncFileResultDecode
  checkBrokerFailureResponse
  checkJsonRpcErrorObjectMapping
  checkReadinessBoundary
  checkRequestArgsBoundary

end RunAtTest.Broker.ProtocolTest

def main := RunAtTest.Broker.ProtocolTest.main
