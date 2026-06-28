/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol

open Lean

namespace Beam.Mcp

def diagnosticSeverityName : Option Lean.Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "information"
  | some .hint => "hint"
  | none => "unknown"

def diagnosticClassification (diagnostic : Beam.Broker.StreamDiagnostic) : String :=
  if diagnostic.saveBlocking?.getD false || diagnostic.completionBlocking then
    "hard_error"
  else
    match diagnostic.severity? with
    | some .error => "soft_failure"
    | some .warning => "warning"
    | some .information | some .hint | none => "info"

def diagnosticJson (diagnostic : Beam.Broker.StreamDiagnostic) : Json :=
  Json.mkObj <|
    [
      ("path", toJson diagnostic.path),
      ("uri", toJson diagnostic.uri),
      ("severity", toJson <| diagnosticSeverityName diagnostic.severity?),
      ("classification", toJson <| diagnosticClassification diagnostic),
      ("range", toJson diagnostic.range),
      ("message", toJson diagnostic.message),
      ("completionBlocking", toJson diagnostic.completionBlocking)
    ] ++
    (match diagnostic.saveBlocking? with
    | some saveBlocking => [("saveBlocking", toJson saveBlocking)]
    | none => []) ++
    match diagnostic.version? with
    | some version => [("version", toJson version)]
    | none => []

end Beam.Mcp
