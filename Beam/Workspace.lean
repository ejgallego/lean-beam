/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Workspace

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

def initModeKeys : Array String :=
  #["set", "verify", "reset"]

instance : ToJson InitMode where
  toJson mode := toJson mode.key

instance : FromJson InitMode where
  fromJson?
    | .str "set" => .ok .set
    | .str "verify" => .ok .verify
    | .str "reset" => .ok .reset
    | j => .error s!"expected init workspace mode 'set', 'verify', or 'reset', got {j.compress}"

/-- Shared input for explicit Beam workspace/session initialization. -/
structure InitInput where
  root : String
  mode? : Option InitMode := none

def InitInput.mode (input : InitInput) : InitMode :=
  input.mode?.getD .set

instance : ToJson InitInput where
  toJson input :=
    Json.mkObj <|
      [("root", toJson input.root)] ++
      match input.mode? with
      | some mode => [("mode", toJson mode)]
      | none => []

instance : FromJson InitInput where
  fromJson? j := do
    let root ← j.getObjValAs? String "root"
    let mode? ← optionalField? (α := InitMode) j "mode"
    pure { root, mode? }

structure InitResult where
  root : System.FilePath
  mode : InitMode
  alreadyInitialized : Bool

instance : ToJson InitResult where
  toJson result :=
    Json.mkObj [
      ("root", toJson result.root.toString),
      ("active_root", toJson result.root.toString),
      ("initialized", toJson true),
      ("mode", toJson result.mode),
      ("already_initialized", toJson result.alreadyInitialized)
    ]

def addActiveRoot (root : System.FilePath) (json : Json) : Json :=
  json.setObjVal! "active_root" (toJson root.toString)

structure InitError where
  message : String
  activeRoot? : Option System.FilePath := none

instance : ToString InitError where
  toString err := err.message

structure InitState where
  root? : Option System.FilePath := none
  runtimeReady : Bool := false
  workspaceUsed : Bool := false

structure InitPlan where
  root : System.FilePath
  mode : InitMode
  alreadyInitialized : Bool
  resetCurrent : Bool
  createRuntime : Bool

def planInit (state : InitState) (requestedRoot : System.FilePath) (mode : InitMode) :
    Except InitError InitPlan := do
  match state.root? with
  | some currentRoot =>
      if currentRoot == requestedRoot then
        if state.runtimeReady then
          pure {
            root := currentRoot
            mode
            alreadyInitialized := true
            resetCurrent := false
            createRuntime := false
          }
        else if mode == .verify then
          pure {
            root := currentRoot
            mode
            alreadyInitialized := false
            resetCurrent := false
            createRuntime := false
          }
        else
          pure {
            root := currentRoot
            mode
            alreadyInitialized := false
            resetCurrent := false
            createRuntime := true
          }
      else
        match mode with
        | .set | .verify =>
            throw {
              message :=
                s!"workspace session is already initialized for {currentRoot}; use mode=reset before opening files or restart the session to use {requestedRoot}"
              activeRoot? := some currentRoot
            }
        | .reset =>
            if state.workspaceUsed then
              throw {
                message :=
                  s!"cannot reset workspace session from {currentRoot} to {requestedRoot} after workspace tools have run; restart the session"
                activeRoot? := some currentRoot
              }
            else
              pure {
                root := requestedRoot
                mode
                alreadyInitialized := false
                resetCurrent := state.runtimeReady
                createRuntime := true
              }
  | none =>
      if mode == .verify then
        throw { message := "workspace session is not initialized; call init workspace with mode=set first" }
      else
        pure {
          root := requestedRoot
          mode
          alreadyInitialized := false
          resetCurrent := false
          createRuntime := true
        }

def initResult (plan : InitPlan) (root : System.FilePath := plan.root) : InitResult := {
  root
  mode := plan.mode
  alreadyInitialized := plan.alreadyInitialized
}

end Beam.Workspace
