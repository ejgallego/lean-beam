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
  | runWith
  | runWithLinear
  | release
  | sync
  | deps
  | save
  | close
  deriving BEq, Repr

def Operation.all : Array Operation := #[
  .runAt,
  .runAtHandle,
  .hover,
  .goalsAfter,
  .goalsPrev,
  .runWith,
  .runWithLinear,
  .release,
  .sync,
  .deps,
  .save,
  .close
]

def Operation.key : Operation → String
  | .runAt => "run_at"
  | .runAtHandle => "run_at_handle"
  | .hover => "hover"
  | .goalsAfter => "goals_after"
  | .goalsPrev => "goals_prev"
  | .runWith => "run_with"
  | .runWithLinear => "run_with_linear"
  | .release => "release"
  | .sync => "sync"
  | .deps => "deps"
  | .save => "save"
  | .close => "close"

instance : ToJson Operation where
  toJson op := toJson op.key

def Operation.description : Operation → String
  | .runAt => "Run Lean text at a file position without storing follow-up state."
  | .runAtHandle => "Run Lean text at a file position and store a follow-up handle."
  | .hover => "Inspect Lean hover information at a file position."
  | .goalsAfter => "Inspect Lean goals after a file position."
  | .goalsPrev => "Inspect Lean goals before a file position."
  | .runWith => "Run Lean text from a stored handle without consuming the parent handle."
  | .runWithLinear => "Run Lean text from a stored handle and consume that handle on success or failure."
  | .release => "Release a stored Lean follow-up handle."
  | .sync => "Synchronize a Lean file with the broker and wait for diagnostics."
  | .deps => "Refresh direct Lean dependency state for a file."
  | .save => "Synchronize a Lean file and save zero-build artifacts when possible."
  | .close => "Close a Lean file in the broker session."

open Beam.JsonSchema in
def Operation.inputSchema : Operation → Json
  | .runAt | .runAtHandle =>
      inputObject [
        ("path", string "Lean file path, relative to the server root unless absolute."),
        ("line", natural "Zero-based LSP line."),
        ("character", natural "Zero-based UTF-16 LSP character."),
        ("text", string "Lean text to run at the selected position.")
      ] #["path", "line", "character", "text"]
  | .hover | .goalsAfter | .goalsPrev =>
      inputObject [
        ("path", string "Lean file path, relative to the server root unless absolute."),
        ("line", natural "Zero-based LSP line."),
        ("character", natural "Zero-based UTF-16 LSP character.")
      ] #["path", "line", "character"]
  | .runWith | .runWithLinear =>
      inputObject [
        ("path", string "Lean file path, relative to the server root unless absolute."),
        ("handle", object "Opaque broker-wrapped Lean handle from a previous tool result."),
        ("text", string "Lean continuation text to run from the stored handle.")
      ] #["path", "handle", "text"]
  | .release =>
      inputObject [
        ("path", string "Lean file path, relative to the server root unless absolute."),
        ("handle", object "Opaque broker-wrapped Lean handle to release.")
      ] #["path", "handle"]
  | .sync | .save =>
      inputObject [
        ("path", string "Lean file path, relative to the server root unless absolute."),
        ("full_diagnostics", bool "When true, include full diagnostics in broker diagnostic streams.")
      ] #["path"]
  | .deps | .close =>
      inputObject [
        ("path", string "Lean file path, relative to the server root unless absolute.")
      ] #["path"]

def Operation.expectsRunAtResult : Operation → Bool
  | .runAt | .runAtHandle | .runWith | .runWithLinear => true
  | _ => false

/-- Input for position-based Lean execution. Coordinates use LSP zero-based line/character units. -/
structure RunAtInput where
  path : String
  line : Nat
  character : Nat
  text : String
  deriving FromJson, ToJson

/-- Input for position-based Lean inspection operations. -/
structure PositionInput where
  path : String
  line : Nat
  character : Nat
  deriving FromJson, ToJson

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

private def optionalField? [FromJson α] (j : Json) (field : String) : Except String (Option α) := do
  match j.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

/-- Input for sync/save operations that may request full diagnostics. -/
structure SyncInput where
  path : String
  fullDiagnostics? : Option Bool := none

instance : ToJson SyncInput where
  toJson input :=
    Json.mkObj <|
      [("path", toJson input.path)] ++
      match input.fullDiagnostics? with
      | some fullDiagnostics => [("full_diagnostics", toJson fullDiagnostics)]
      | none => []

instance : FromJson SyncInput where
  fromJson? j := do
    let path ← j.getObjValAs? String "path"
    let fullDiagnostics? ← optionalField? (α := Bool) j "full_diagnostics"
    pure { path, fullDiagnostics? }

def RunAtInput.toBrokerRequest
    (input : RunAtInput)
    (root : String)
    (storeHandle : Bool := false) : Beam.Broker.Request := {
  op := .runAt
  backend := .lean
  root? := some root
  path? := some input.path
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
  line? := some input.line
  character? := some input.character
  mode? := some mode
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

def PathInput.toDepsBrokerRequest (input : PathInput) (root : String) : Beam.Broker.Request := {
  op := .deps
  backend := .lean
  root? := some root
  path? := some input.path
}

def PathInput.toCloseBrokerRequest (input : PathInput) (root : String) : Beam.Broker.Request := {
  op := .close
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
  | .runWith =>
      pure <| (← fromJson? (α := RunWithInput) input).toBrokerRequest root
  | .runWithLinear =>
      pure <| (← fromJson? (α := RunWithInput) input).toBrokerRequest root (linear := true)
  | .release =>
      pure <| (← fromJson? (α := ReleaseInput) input).toBrokerRequest root
  | .sync =>
      pure <| (← fromJson? (α := SyncInput) input).toSyncBrokerRequest root
  | .deps =>
      pure <| (← fromJson? (α := PathInput) input).toDepsBrokerRequest root
  | .save =>
      pure <| (← fromJson? (α := SyncInput) input).toSaveBrokerRequest root
  | .close =>
      pure <| (← fromJson? (α := PathInput) input).toCloseBrokerRequest root

end Beam.Lean
