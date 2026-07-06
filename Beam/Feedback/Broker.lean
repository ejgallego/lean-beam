/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol

open Lean

namespace Beam.Feedback

def responsePayloadOrWarning
    (label : String)
    (resp : Beam.Broker.Response)
    (warnings : Array String) : Json × Array String :=
  if resp.ok then
    match resp.result? with
    | some result => (result, warnings)
    | none => (Json.null, warnings.push s!"{label} returned no result payload")
  else
    let errText := (resp.error?.map (fun err => s!"{err.code}: {err.message}")).getD "unknown error"
    (Json.null, warnings.push s!"{label} failed: {errText}")

end Beam.Feedback
