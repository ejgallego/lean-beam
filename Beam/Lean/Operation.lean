/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import Beam.JsonSchema

open Lean

namespace Beam.Lean

/--
Curated Lean operations that Beam exposes above the raw LSP layer.

CLI and MCP projections should map to these operations instead of constructing broker requests
independently or exposing raw LSP methods.
-/
inductive Operation where
  | runAt
  | runAtHandle
  | hover
  | goalsAfter
  | goalsPrev
  | todo
  | runWith
  | runWithLinear
  | release
  | update
  | sync
  | save
  | close
  deriving BEq, Repr

def Operation.all : Array Operation := #[
  .runAt,
  .runAtHandle,
  .hover,
  .goalsAfter,
  .goalsPrev,
  .todo,
  .runWith,
  .runWithLinear,
  .release,
  .update,
  .sync,
  .save,
  .close
]

def Operation.key : Operation → String
  | .runAt => "run_at"
  | .runAtHandle => "run_at_handle"
  | .hover => "hover"
  | .goalsAfter => "goals_after"
  | .goalsPrev => "goals_prev"
  | .todo => "todo"
  | .runWith => "run_with"
  | .runWithLinear => "run_with_linear"
  | .release => "release"
  | .update => "update"
  | .sync => "sync"
  | .save => "save"
  | .close => "close"

instance : ToJson Operation where
  toJson op := toJson op.key

def Operation.description : Operation → String
  | .runAt => "Run one Lean command or tactic block at a file position without storing follow-up state."
  | .runAtHandle => "Run one Lean command or tactic block at a file position and store a follow-up handle."
  | .hover => "Inspect Lean hover information at a file position."
  | .goalsAfter => "Inspect Lean goals after a file position."
  | .goalsPrev => "Inspect Lean goals before a file position."
  | .todo => "Inspect agent-actionable Lean todo items in a file range."
  | .runWith => "Run one Lean continuation command or tactic block from a stored handle without consuming the parent handle."
  | .runWithLinear => "Run one Lean continuation command or tactic block from a stored handle and consume that handle on success or failure."
  | .release => "Release a stored Lean follow-up handle."
  | .update => "Open or update a Lean file in the broker and return its document version without waiting for diagnostics."
  | .sync => "Synchronize a Lean file with the broker and wait for diagnostics."
  | .save => "Synchronize a Lean file and save zero-build artifacts when possible."
  | .close => "Close a Lean file in the broker session."

private def pathField : String × Json :=
  ("path", Beam.JsonSchema.string "Lean file path, relative to the server root unless absolute.")

private def versionField : String × Json :=
  ("version", Beam.JsonSchema.natural "Document version returned by a successful lean_update or lean_sync for this file.")

private def lineField : String × Json :=
  ("line", Beam.JsonSchema.natural "Zero-based LSP line.")

private def characterField : String × Json :=
  ("character", Beam.JsonSchema.natural "Zero-based UTF-16 LSP character.")

private def rangeStartLineField : String × Json :=
  ("start_line", Beam.JsonSchema.natural "Zero-based LSP start line.")

private def rangeStartCharacterField : String × Json :=
  ("start_character", Beam.JsonSchema.natural "Zero-based UTF-16 LSP start character.")

private def rangeEndLineField : String × Json :=
  ("end_line", Beam.JsonSchema.natural "Zero-based LSP end line.")

private def rangeEndCharacterField : String × Json :=
  ("end_character", Beam.JsonSchema.natural "Zero-based UTF-16 LSP end character.")

private def runAtTextField : String × Json :=
  ("text", Beam.JsonSchema.string "One Lean command or tactic block to run at the selected position. Top-level command sequences are not accepted by one runAt call.")

private def continuationTextField : String × Json :=
  ("text", Beam.JsonSchema.string "One Lean continuation command or tactic block to run from the stored handle.")

private def handleField : String × Json :=
  ("handle", Beam.JsonSchema.object "Opaque broker-wrapped Lean handle from a previous tool result.")

private def releaseHandleField : String × Json :=
  ("handle", Beam.JsonSchema.object "Opaque broker-wrapped Lean handle to release.")

private def kindsField : String × Json :=
  ("kinds", Beam.JsonSchema.enumStringArray "Todo kinds to include. Omit or pass [] for all kinds."
    RunAt.TodoKind.allKeys)

private def suggestField : String × Json :=
  ("suggest", Beam.JsonSchema.enumString "Suggestion mode for optional run_at_text hints."
    RunAt.TodoSuggestMode.allKeys)

private def syncFullDiagnosticsField : String × Json :=
  ("full_diagnostics", Beam.JsonSchema.bool
    "When true, include warnings, information, and hints in streamed or replayed diagnostics; false keeps diagnostic output error-only while summaries remain complete.")

private def saveFullDiagnosticsField : String × Json :=
  ("full_diagnostics", Beam.JsonSchema.bool
    "When true, include warnings, information, and hints in streamed diagnostics; false keeps diagnostic output error-only while summaries remain complete.")

private def includeDiagnosticsField : String × Json :=
  ("include_diagnostics", Beam.JsonSchema.bool
    "When true, include the current request diagnostics in the final sync result; the full_diagnostics setting controls the severity filter.")

private def positionFields : List (String × Json) :=
  [pathField, versionField, lineField, characterField]

private def rangeFields : List (String × Json) :=
  [
    pathField,
    versionField,
    rangeStartLineField,
    rangeStartCharacterField,
    rangeEndLineField,
    rangeEndCharacterField
  ]

open Beam.JsonSchema in
def Operation.inputSchema : Operation → Json
  | .runAt | .runAtHandle =>
      inputObject (positionFields ++ [runAtTextField]) #["path", "version", "line", "character", "text"]
  | .hover | .goalsAfter | .goalsPrev =>
      inputObject positionFields #["path", "version", "line", "character"]
  | .todo =>
      inputObject (rangeFields ++ [kindsField, suggestField])
        #["path", "version", "start_line", "start_character", "end_line", "end_character"]
  | .runWith | .runWithLinear =>
      inputObject [pathField, handleField, continuationTextField] #["path", "handle", "text"]
  | .release =>
      inputObject [pathField, releaseHandleField] #["path", "handle"]
  | .update =>
      inputObject [pathField] #["path"]
  | .sync =>
      inputObject [pathField, syncFullDiagnosticsField, includeDiagnosticsField] #["path"]
  | .save =>
      inputObject [pathField, saveFullDiagnosticsField] #["path"]
  | .close =>
      inputObject [pathField] #["path"]

def Operation.expectsRunAtResult : Operation → Bool
  | .runAt | .runAtHandle | .runWith | .runWithLinear => true
  | _ => false

/-- Input for position-based Lean execution. Coordinates use LSP zero-based line/character units. -/
structure RunAtInput where
  path : String
  version : Nat
  line : Nat
  character : Nat
  text : String
  deriving FromJson, ToJson

/-- Input for position-based Lean inspection operations. -/
structure PositionInput where
  path : String
  version : Nat
  line : Nat
  character : Nat
  deriving FromJson, ToJson

private def optionalField? [FromJson α] (j : Json) (field : String) : Except String (Option α) := do
  match j.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

/-- Input for range-based Lean todo inspection operations. -/
structure TodoInput where
  path : String
  version : Nat
  startLine : Nat
  startCharacter : Nat
  endLine : Nat
  endCharacter : Nat
  kinds? : Option (Array RunAt.TodoKind) := none
  suggest? : Option RunAt.TodoSuggestMode := none

instance : ToJson TodoInput where
  toJson input :=
    Json.mkObj <|
      [ ("path", toJson input.path)
      , ("version", toJson input.version)
      , ("start_line", toJson input.startLine)
      , ("start_character", toJson input.startCharacter)
      , ("end_line", toJson input.endLine)
      , ("end_character", toJson input.endCharacter)
      ] ++
      (match input.kinds? with
      | some kinds => [("kinds", toJson kinds)]
      | none => []) ++
      (match input.suggest? with
      | some suggest => [("suggest", toJson suggest)]
      | none => [])

instance : FromJson TodoInput where
  fromJson? j := do
    let path ← j.getObjValAs? String "path"
    let version ← j.getObjValAs? Nat "version"
    let startLine ← j.getObjValAs? Nat "start_line"
    let startCharacter ← j.getObjValAs? Nat "start_character"
    let endLine ← j.getObjValAs? Nat "end_line"
    let endCharacter ← j.getObjValAs? Nat "end_character"
    let kinds? ← optionalField? (α := Array RunAt.TodoKind) j "kinds"
    let suggest? ← optionalField? (α := RunAt.TodoSuggestMode) j "suggest"
    pure { path, version, startLine, startCharacter, endLine, endCharacter, kinds?, suggest? }

/-- Input for handle-based Lean execution. -/
structure RunWithInput where
  path : String
  handle : Beam.Broker.Handle
  text : String
  deriving FromJson, ToJson

/-- Input for explicit handle release. -/
structure ReleaseInput where
  path : String
  handle : Beam.Broker.Handle
  deriving FromJson, ToJson

/-- Input for path-scoped operations without extra flags. -/
structure PathInput where
  path : String
  deriving FromJson, ToJson

/-- Input for sync/save operations that may request full diagnostics. -/
structure SyncInput where
  path : String
  fullDiagnostics? : Option Bool := none
  includeDiagnostics? : Option Bool := none

instance : ToJson SyncInput where
  toJson input :=
    Json.mkObj <|
      [("path", toJson input.path)] ++
      (match input.fullDiagnostics? with
      | some fullDiagnostics => [("full_diagnostics", toJson fullDiagnostics)]
      | none => []) ++
      (match input.includeDiagnostics? with
      | some includeDiagnostics => [("include_diagnostics", toJson includeDiagnostics)]
      | none => [])

instance : FromJson SyncInput where
  fromJson? j := do
    let path ← j.getObjValAs? String "path"
    let fullDiagnostics? ← optionalField? (α := Bool) j "full_diagnostics"
    let includeDiagnostics? ← optionalField? (α := Bool) j "include_diagnostics"
    pure { path, fullDiagnostics?, includeDiagnostics? }

def RunAtInput.toBrokerRequest
    (input : RunAtInput)
    (root : String)
    (storeHandle : Bool := false) : Beam.Broker.Request := {
  op := .runAt
  backend := .lean
  root? := some root
  path? := some input.path
  version? := some input.version
  line? := some input.line
  character? := some input.character
  text? := some input.text
  storeHandle? := if storeHandle then some true else none
}

def PositionInput.toHoverBrokerRequest (input : PositionInput) (root : String) : Beam.Broker.Request := {
  op := .requestAt
  backend := .lean
  root? := some root
  path? := some input.path
  version? := some input.version
  line? := some input.line
  character? := some input.character
  method? := some "textDocument/hover"
}

def PositionInput.toGoalsBrokerRequest
    (input : PositionInput)
    (root : String)
    (mode : Beam.Broker.GoalMode) : Beam.Broker.Request := {
  op := .goals
  backend := .lean
  root? := some root
  path? := some input.path
  version? := some input.version
  line? := some input.line
  character? := some input.character
  mode? := some mode
}

def TodoInput.toBrokerRequest (input : TodoInput) (root : String) : Beam.Broker.Request := {
  op := .todo
  backend := .lean
  root? := some root
  path? := some input.path
  version? := some input.version
  line? := some input.startLine
  character? := some input.startCharacter
  endLine? := some input.endLine
  endCharacter? := some input.endCharacter
  kinds? := input.kinds?
  suggest? := input.suggest?
}

def RunWithInput.toBrokerRequest
    (input : RunWithInput)
    (root : String)
    (linear : Bool := false) : Beam.Broker.Request := {
  op := .runWith
  backend := .lean
  root? := some root
  path? := some input.path
  text? := some input.text
  storeHandle? := some true
  linear? := some linear
  handle? := some input.handle
}

def ReleaseInput.toBrokerRequest (input : ReleaseInput) (root : String) : Beam.Broker.Request := {
  op := .release
  backend := .lean
  root? := some root
  path? := some input.path
  handle? := some input.handle
}

def PathInput.toCloseBrokerRequest (input : PathInput) (root : String) : Beam.Broker.Request := {
  op := .close
  backend := .lean
  root? := some root
  path? := some input.path
}

def PathInput.toUpdateBrokerRequest (input : PathInput) (root : String) : Beam.Broker.Request := {
  op := .updateFile
  backend := .lean
  root? := some root
  path? := some input.path
}

def SyncInput.toSyncBrokerRequest (input : SyncInput) (root : String) : Beam.Broker.Request := {
  op := .syncFile
  backend := .lean
  root? := some root
  path? := some input.path
  fullDiagnostics? := input.fullDiagnostics?
  includeDiagnostics? := input.includeDiagnostics?
}

def SyncInput.toSaveBrokerRequest (input : SyncInput) (root : String) : Beam.Broker.Request := {
  op := .saveOlean
  backend := .lean
  root? := some root
  path? := some input.path
  fullDiagnostics? := input.fullDiagnostics?
}

def Operation.toBrokerRequest
    (op : Operation)
    (root : String)
    (input : Json) : Except String Beam.Broker.Request := do
  match op with
  | .runAt =>
      pure <| (← fromJson? (α := RunAtInput) input).toBrokerRequest root
  | .runAtHandle =>
      pure <| (← fromJson? (α := RunAtInput) input).toBrokerRequest root (storeHandle := true)
  | .hover =>
      pure <| (← fromJson? (α := PositionInput) input).toHoverBrokerRequest root
  | .goalsAfter =>
      pure <| (← fromJson? (α := PositionInput) input).toGoalsBrokerRequest root .after
  | .goalsPrev =>
      pure <| (← fromJson? (α := PositionInput) input).toGoalsBrokerRequest root .prev
  | .todo =>
      pure <| (← fromJson? (α := TodoInput) input).toBrokerRequest root
  | .runWith =>
      pure <| (← fromJson? (α := RunWithInput) input).toBrokerRequest root
  | .runWithLinear =>
      pure <| (← fromJson? (α := RunWithInput) input).toBrokerRequest root (linear := true)
  | .release =>
      pure <| (← fromJson? (α := ReleaseInput) input).toBrokerRequest root
  | .update =>
      pure <| (← fromJson? (α := PathInput) input).toUpdateBrokerRequest root
  | .sync =>
      pure <| (← fromJson? (α := SyncInput) input).toSyncBrokerRequest root
  | .save =>
      pure <| (← fromJson? (α := SyncInput) input).toSaveBrokerRequest root
  | .close =>
      pure <| (← fromJson? (α := PathInput) input).toCloseBrokerRequest root

end Beam.Lean
