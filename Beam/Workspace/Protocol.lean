/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Workspace

abbrev WorkspaceId := String

def defaultWorkspaceId : WorkspaceId :=
  "default"

def validWorkspaceId (workspaceId : WorkspaceId) : Bool :=
  !workspaceId.isEmpty

private def optionalField? [FromJson α] (json : Json) (field : String) : Except String (Option α) := do
  match json.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

inductive InitMode where
  | set
  | verify
  | reset
  deriving BEq, Repr

def InitMode.key : InitMode → String
  | .set => "set"
  | .verify => "verify"
  | .reset => "reset"

def InitMode.all : Array InitMode :=
  #[.set, .verify, .reset]

def initModeKeys : Array String :=
  InitMode.all.map InitMode.key

def InitMode.fromKey? (key : String) : Option InitMode :=
  InitMode.all.find? (fun mode => mode.key == key)

instance : ToJson InitMode where
  toJson mode := toJson mode.key

instance : FromJson InitMode where
  fromJson?
    | .str key =>
        match InitMode.fromKey? key with
        | some mode => .ok mode
        | none =>
            .error <|
              s!"expected init workspace mode 'set', 'verify', or 'reset', got {toJson key |>.compress}"
    | j => .error s!"expected init workspace mode 'set', 'verify', or 'reset', got {j.compress}"

/-- Shared input for explicit Beam workspace/session initialization. -/
structure InitInput where
  root : String
  workspaceId : WorkspaceId
  mode? : Option InitMode := none

def InitInput.mode (input : InitInput) : InitMode :=
  input.mode?.getD .set

instance : ToJson InitInput where
  toJson input :=
    Json.mkObj <|
      [
        ("root", toJson input.root),
        ("workspace_id", toJson input.workspaceId)
      ] ++
      match input.mode? with
      | some mode => [("mode", toJson mode)]
      | none => []

instance : FromJson InitInput where
  fromJson? j := do
    let root ← j.getObjValAs? String "root"
    let rawWorkspaceId ←
      match j.getObjVal? "workspace_id" with
      | .ok rawWorkspaceId => pure rawWorkspaceId
      | .error _ => throw "workspace_id is required"
    let workspaceId ←
      match fromJson? (α := WorkspaceId) rawWorkspaceId with
      | .ok workspaceId => pure workspaceId
      | .error err => throw s!"invalid 'workspace_id': {err}"
    unless validWorkspaceId workspaceId do
      throw "workspace_id must be non-empty"
    let mode? ← optionalField? (α := InitMode) j "mode"
    pure { root, workspaceId, mode? }

structure InitResult where
  workspaceId : WorkspaceId := defaultWorkspaceId
  root : System.FilePath
  mode : InitMode
  runtimeReused : Bool
  previousRoot? : Option System.FilePath := none
  invalidatedHandles : Bool := false

instance : ToJson InitResult where
  toJson result :=
    Json.mkObj <|
      [
        ("workspace_id", toJson result.workspaceId),
        ("root", toJson result.root.toString),
        ("active_root", toJson result.root.toString),
        ("initialized", toJson true),
        ("mode", toJson result.mode),
        ("runtime_reused", toJson result.runtimeReused),
        ("invalidated_handles", toJson result.invalidatedHandles)
      ] ++
      match result.previousRoot? with
      | some previousRoot => [("previous_root", toJson previousRoot.toString)]
      | none => []

end Beam.Workspace
