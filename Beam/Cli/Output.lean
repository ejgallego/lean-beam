/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Args
import Beam.Cli.RuntimeBundle
import Beam.Broker.Client
import RunAt.Protocol

open Lean

namespace Beam.Cli

open Beam.Broker

def printJsonLine (json : Json) : IO Unit := do
  IO.println json.pretty

def envClientRequestId? : IO (Option String) := do
  match ← IO.getEnv "BEAM_REQUEST_ID" with
  | some raw =>
      let trimmed := raw.trimAscii.toString
      pure <| if trimmed.isEmpty then none else some trimmed
  | none =>
      pure none

def withEnvClientRequestId (req : Request) : IO Request := do
  pure { req with clientRequestId? := req.clientRequestId? <|> (← envClientRequestId?) }

def annotateRunatMessage (clientRequestId? : Option String) (msg : String) : String :=
  match clientRequestId? with
  | some clientRequestId =>
      if msg.startsWith "beam:" then
        s!"beam[{clientRequestId}]:" ++ (msg.drop 6).toString
      else
        s!"beam[{clientRequestId}]: {msg}"
  | none =>
      msg

private def debugTextEnabled : IO Bool := do
  pure <| (← envFlag? "BEAM_DEBUG_TEXT").getD false

def maybeEmitTextDebug (clientRequestId? : Option String) (action source : String) (text? : Option String) : IO Unit := do
  if !(← debugTextEnabled) then
    pure ()
  else
    match text? with
    | none => pure ()
    | some text =>
        let bytes := text.toUTF8
        let containsLiteralBackslashN := hasSubstring text "\\n"
        IO.eprintln <| annotateRunatMessage clientRequestId?
          s!"beam: debug text for {action}: source={source} utf8Bytes={bytes.size} containsNewline={boolText (text.contains '\n')} containsLiteralBackslashN={boolText containsLiteralBackslashN}"
        IO.eprintln <| annotateRunatMessage clientRequestId?
          s!"beam: debug text escaped={(Json.str text).compress}"
        IO.eprintln <| annotateRunatMessage clientRequestId?
          s!"beam: debug text utf8Hex={utf8Hex bytes}"

def decodeRunAtResult? (resp : Response) : Option RunAt.Result :=
  match resp.result? with
  | none => none
  | some result =>
      match fromJson? result with
      | .ok payload => some payload
      | .error _ => none

def responseErrorSummary? (action failureBoundary : String) (resp : Response) : Option String :=
  resp.error?.map fun err =>
    s!"beam: {action} request failed {failureBoundary} ({err.code}): {err.message}"

def runAtPayloadSummary? (action noun : String) (resp : Response) : Option String :=
  match decodeRunAtResult? resp with
  | some result =>
      if result.success then
        none
      else
        some s!"beam: {action} {noun} failed inside Lean; the request completed and returned result.success=false"
  | none =>
      none

def maybeEmitLiteralBackslashNewlineHint (req : Request) (resp : Response) : IO Unit := do
  match req.op with
  | .runAt | .runWith =>
      match req.text?, decodeRunAtResult? resp with
      | some text, some result =>
          if !result.success && hasSubstring text "\\n" && !text.contains '\n' then
            IO.eprintln <| annotateRunatMessage req.clientRequestId?
              "beam: hint: the probe text contains the literal characters '\\n'; if you meant a real newline, use --stdin or --text-file."
          else
            pure ()
      | _, _ =>
          pure ()
  | _ =>
      pure ()

def decodeSyncFileResult? (resp : Response) : Option SyncFileResult := do
  let result ← resp.result?
  fromJson? result |>.toOption

def responseFileProgress? (resp : Response) : Option SyncFileProgress :=
  resp.fileProgress?

def syncFileProgressSuffix (progress? : Option SyncFileProgress) : String :=
  match progress? with
  | none => ""
  | some progress =>
      let doneSuffix :=
        if progress.done then
          ""
        else
          " done=false"
      s!", fp updates={progress.updates}{doneSuffix}"

end Beam.Cli
