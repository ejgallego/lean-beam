/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace BeamTest.Broker.JsonAssert

def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

def requireObjVal (label field : String) (json : Json) : IO Json := do
  match json.getObjVal? field with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label}: missing field {field}: {err}\n{json.compress}"

def requireFieldPresent (label field : String) (json : Json) : IO Unit := do
  discard <| requireObjVal label field json

def requireFieldAbsent (label field : String) (json : Json) : IO Unit := do
  match json.getObjVal? field with
  | .ok _ => throw <| IO.userError s!"{label}: unexpected field {field}: {json.compress}"
  | .error _ => pure ()

def requireJsonString (label field expected : String) (json : Json) : IO Unit := do
  match json.getObjValAs? String field with
  | .ok actual =>
      if actual != expected then
        throw <| IO.userError s!"{label}: expected {field}={expected}, got {json.compress}"
  | .error err =>
      throw <| IO.userError s!"{label}: invalid string field {field}: {err}\n{json.compress}"

def requireJsonInt (label field : String) (expected : Int) (json : Json) : IO Unit := do
  match json.getObjValAs? Int field with
  | .ok actual =>
      if actual != expected then
        throw <| IO.userError s!"{label}: expected {field}={expected}, got {json.compress}"
  | .error err =>
      throw <| IO.userError s!"{label}: invalid int field {field}: {err}\n{json.compress}"

def requireJsonBool (label field : String) (expected : Bool) (json : Json) : IO Unit := do
  match json.getObjValAs? Bool field with
  | .ok actual =>
      if actual != expected then
        throw <| IO.userError s!"{label}: expected {field}={expected}, got {json.compress}"
  | .error err =>
      throw <| IO.userError s!"{label}: invalid bool field {field}: {err}\n{json.compress}"

def requireJsonNull (label field : String) (json : Json) : IO Unit := do
  match ← requireObjVal label field json with
  | Json.null => pure ()
  | value => throw <| IO.userError s!"{label}: expected {field}=null, got {value.compress}"

def expectOk (label : String) (result : Except ε α) [ToString ε] : IO α := do
  match result with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label}: {err}"

end BeamTest.Broker.JsonAssert
