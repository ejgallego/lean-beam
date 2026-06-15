/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.JsonSchema

/-- JSON Schema revision used by Beam's agent-facing tool schemas. -/
def dialect : String :=
  "https://json-schema.org/draft/2020-12/schema"

def string (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "string"),
    ("description", toJson description)
  ]

def enumString (description : String) (values : Array String) : Json :=
  Json.mkObj [
    ("type", toJson "string"),
    ("description", toJson description),
    ("enum", toJson values)
  ]

def enumStringArray (description : String) (values : Array String) : Json :=
  Json.mkObj [
    ("type", toJson "array"),
    ("description", toJson description),
    ("items", enumString description values)
  ]

def natural (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "integer"),
    ("minimum", toJson (0 : Nat)),
    ("description", toJson description)
  ]

def bool (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "boolean"),
    ("description", toJson description)
  ]

def object (description : String) : Json :=
  Json.mkObj [
    ("type", toJson "object"),
    ("description", toJson description)
  ]

/--
Construct a closed object input schema for public operation surfaces.

Beam tool inputs are deliberately small and explicit. Keeping `additionalProperties=false` at this
shared boundary prevents CLI/MCP projections from accepting undeclared fields by accident.
-/
def inputObject (properties : List (String × Json)) (required : Array String) : Json :=
  Json.mkObj [
    ("$schema", toJson dialect),
    ("type", toJson "object"),
    ("properties", Json.mkObj properties),
    ("required", toJson required),
    ("additionalProperties", toJson false)
  ]

end Beam.JsonSchema
