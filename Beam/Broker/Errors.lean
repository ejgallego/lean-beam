/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol

open Lean

namespace Beam.Broker

inductive BrokerFailureCode where
  | invalidParams
  | requestCancelled
  | contentModified
  | workerExited
  | syncBarrierIncomplete
  | saveTraceStale
  | saveTargetNotModule
  | internalError
  deriving Inhabited, BEq, Repr

def BrokerFailureCode.name : BrokerFailureCode → String
  | .invalidParams => "invalidParams"
  | .requestCancelled => "requestCancelled"
  | .contentModified => "contentModified"
  | .workerExited => "workerExited"
  | .syncBarrierIncomplete => syncBarrierIncompleteCode
  | .saveTraceStale => saveTraceStaleCode
  | .saveTargetNotModule => saveTargetNotModuleCode
  | .internalError => "internalError"

instance : ToJson BrokerFailureCode where
  toJson code := toJson code.name

instance : FromJson BrokerFailureCode where
  fromJson? j :=
    match j with
    | .str "invalidParams" => .ok .invalidParams
    | .str "requestCancelled" => .ok .requestCancelled
    | .str "contentModified" => .ok .contentModified
    | .str "workerExited" => .ok .workerExited
    | .str s =>
        if s == syncBarrierIncompleteCode then
          .ok .syncBarrierIncomplete
        else if s == saveTraceStaleCode then
          .ok .saveTraceStale
        else if s == saveTargetNotModuleCode then
          .ok .saveTargetNotModule
        else if s == "internalError" then
          .ok .internalError
        else
          .error s!"expected broker failure code, got {j.compress}"
    | _ => .error s!"expected broker failure code, got {j.compress}"

structure BrokerFailure where
  code : BrokerFailureCode
  message : String := ""
  data? : Option Json := none
  deriving Inhabited, FromJson, ToJson

private def brokerFailurePrefix : String :=
  "brokerfail:"

def BrokerFailure.toResponse (failure : BrokerFailure) : Response :=
  {
    ok := false
    error? := some {
      code := failure.code.name
      message := failure.message
      data? := failure.data?
    }
  }

def brokerFailureMessage (failure : BrokerFailure) : String :=
  s!"{brokerFailurePrefix}{(toJson failure).compress}"

def throwBrokerFailure (failure : BrokerFailure) : IO α := do
  throw <| IO.userError (brokerFailureMessage failure)

def decodeBrokerFailure? (msg : String) : Option BrokerFailure := do
  guard <| msg.startsWith brokerFailurePrefix
  let raw := msg.drop brokerFailurePrefix.length |>.toString
  let json ← Json.parse raw |>.toOption
  fromJson? json |>.toOption

def reqError (code : String) (message : String := "") (data? : Option Json := none) : Response :=
  Response.error code message data?

def errorCodeName : JsonRpc.ErrorCode → String
  | .parseError => "parseError"
  | .invalidRequest => "invalidRequest"
  | .methodNotFound => "methodNotFound"
  | .invalidParams => "invalidParams"
  | .internalError => "internalError"
  | .serverNotInitialized => "serverNotInitialized"
  | .unknownErrorCode => "unknownErrorCode"
  | .contentModified => "contentModified"
  | .requestCancelled => "requestCancelled"
  | .rpcNeedsReconnect => "rpcNeedsReconnect"
  | .workerExited => "workerExited"
  | .workerCrashed => "workerCrashed"

private def decodeJsonRpcErrorObject (json : Json) : Option Response :=
  match json.getObjVal? "code", json.getObjVal? "message" with
  | .ok code, .ok (.str message) =>
      match fromJson? code with
      | .ok (errCode : JsonRpc.ErrorCode) => some <| reqError (errorCodeName errCode) message
      | .error _ => some <| reqError code.compress message
  | _, _ => none

private def decodeJsonRpcErrorPayload (json : Json) : Option Response :=
  decodeJsonRpcErrorObject json <|>
    match json.getObjVal? "error" with
    | .ok errJson => decodeJsonRpcErrorObject errJson
    | .error _ => none

/-
Rocq-side goal probes can surface valid LSP/server error codes that Lean's JSON-RPC reader does not
recognize on the normal `.responseError` path. In particular, `rocq-goals-prev` with injected text
can trip a `coq-lsp` error such as `-32803` ("Expected a single focused goal but 0 goals are
focused."). When that happens, we may only see the embedded JSON error payload inside the thrown
`Cannot read LSP message: JSON '…'` text, so keep this fallback decoder tolerant of both direct
`jsonrpcerr:` payloads and embedded `{"error": ...}` objects instead of collapsing them to a plain
`internalError`.
-/
def decodeJsonRpcError (msg : String) : Option Response :=
  let decodeParsed (raw : String) : Option Response :=
    match Json.parse raw with
    | .error _ => some <| reqError "internalError" msg
    | .ok json =>
        match decodeJsonRpcErrorPayload json with
        | some resp => some resp
        | none => some <| reqError "internalError" msg
  if msg.startsWith "jsonrpcerr:" then
    decodeParsed (msg.drop 11 |>.toString)
  else if msg.startsWith "Cannot read LSP message: JSON '" then
    let raw := (msg.drop 31).toString
    match (raw.splitOn "' did not have the format of a JSON-RPC message.").head? with
    | some embedded => decodeParsed embedded
    | none => none
  else
    none

private def isSyncBarrierIncompleteMessage (msg : String) : Bool :=
  msg.startsWith "Lean diagnostics barrier did not complete for "

private def isSaveTargetNotModuleMessage (msg : String) : Bool :=
  msg.startsWith "could not resolve a Lake module for "

private def isSaveTraceStaleMessage (msg : String) : Bool :=
  msg.startsWith "Lake save trace is stale for "

private def isRequestCancelledMessage (msg : String) : Bool :=
  msg.startsWith "requestCancelled:"

private def isContentModifiedMessage (msg : String) : Bool :=
  msg.startsWith "contentModified:"

private def isWorkerExitedMessage (msg : String) : Bool :=
  msg.startsWith "workerExited:"

def responseForExceptionMessage (msg : String) : Response :=
  if let some failure := decodeBrokerFailure? msg then
    failure.toResponse
  else if isRequestCancelledMessage msg then
    reqError "requestCancelled" msg
  else if isContentModifiedMessage msg then
    reqError "contentModified" msg
  else if isWorkerExitedMessage msg then
    reqError "workerExited" msg
  else if isSyncBarrierIncompleteMessage msg then
    reqError syncBarrierIncompleteCode msg
  else if isSaveTraceStaleMessage msg then
    reqError saveTraceStaleCode msg
  else if isSaveTargetNotModuleMessage msg then
    reqError saveTargetNotModuleCode msg
  else if let some resp := decodeJsonRpcError msg then
    resp
  else
    reqError "internalError" msg

end Beam.Broker
