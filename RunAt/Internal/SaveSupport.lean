 /-
 Copyright (c) 2026 Lean FRO LLC. All rights reserved.
 Released under Apache 2.0 license as described in the file LICENSE.
 Author: Emilio J. Gallego Arias
 -/

 import Lean

 open Lean

 namespace RunAt.Internal

 /--
 Internal broker-only request for saving the current elaborated document state to
 the Lake artifact locations expected by the workspace.

 This underpins the supported `save after sync` path. It is not part of the public
 `runAt` API.
 -/
 def saveArtifactsMethod : String := "$/lean/runAt/saveArtifacts"

 /--
 Internal broker-only request for checking whether the current elaborated document
 state is ready for artifact save.

 This underpins the supported `save after sync` path. It is not part of the public
 `runAt` API.
 -/
 def saveReadinessMethod : String := "$/lean/runAt/saveReadiness"

/-- Internal request payload for artifact serialization from the current worker snapshot. -/
structure SaveArtifactsParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  expectedVersion : Nat
  expectedTextHash : UInt64
  oleanFile : String
  ileanFile : String
  cFile : String
  bcFile? : Option String := none
  deriving FromJson, ToJson

-- Keep this indirection while v4.28 stays supported; see the compat note in `RunAt.Protocol`.
instance : Lean.Lsp.FileSource SaveArtifactsParams where
   fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Internal request payload for save-readiness checks from the current worker snapshot. -/
structure SaveReadinessParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  expectedVersion : Nat
  expectedTextHash : UInt64
  deriving FromJson, ToJson

-- Keep this indirection while v4.28 stays supported; see the compat note in `RunAt.Protocol`.
instance : Lean.Lsp.FileSource SaveReadinessParams where
   fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Internal success payload for artifact serialization. -/
structure SaveArtifactsResult where
  written : Bool := true
  version : Nat
  textHash : UInt64
  deriving FromJson, ToJson

/-- Diagnostic-shaped evidence for an error that participates in save-readiness. -/
structure SaveBlockingDiagnostic where
  range : Lean.Lsp.Range
  severity? : Option Lean.Lsp.DiagnosticSeverity := some .error
  message : String
  saveBlocking : Bool := true
  completionBlocking : Bool := false
  deriving FromJson, ToJson

/-- Frontend command-message evidence for an error that participates in save-readiness. -/
structure SaveBlockingCommandMessage where
  message : String
  saveBlocking : Bool := true
  completionBlocking : Bool := false
  deriving FromJson, ToJson

private def optionalField? [FromJson α] (json : Json) (field : String) : Except String (Option α) := do
  match json.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

/-- Internal success payload for save-readiness checks. -/
structure SaveReadinessResult where
  version : Nat
  /-- Current worker snapshot diagnostics for reporting, not the save-readiness verdict. -/
  currentDiagnostics : Array Lean.Lsp.Diagnostic := #[]
  currentWarningCount : Nat := 0
  saveReady : Bool := true
  saveReadyReason : String := "ok"
  saveReadyMessage? : Option String := none
  blockingDiagnostics : Array SaveBlockingDiagnostic := #[]
  blockingCommandMessages : Array SaveBlockingCommandMessage := #[]
  deriving ToJson

instance : FromJson SaveReadinessResult where
  fromJson? json := do
    let version ← json.getObjValAs? Nat "version"
    let currentDiagnostics? ←
      optionalField? (α := Array Lean.Lsp.Diagnostic) json "currentDiagnostics"
    let currentWarningCount? ← optionalField? (α := Nat) json "currentWarningCount"
    let saveReady? ← optionalField? (α := Bool) json "saveReady"
    let saveReadyReason? ← optionalField? (α := String) json "saveReadyReason"
    let saveReadyMessage? ← optionalField? (α := String) json "saveReadyMessage"
    let blockingDiagnostics? ←
      optionalField? (α := Array SaveBlockingDiagnostic) json "blockingDiagnostics"
    let blockingCommandMessages? ←
      optionalField? (α := Array SaveBlockingCommandMessage) json "blockingCommandMessages"
    pure {
      version
      currentDiagnostics := currentDiagnostics?.getD #[]
      currentWarningCount := currentWarningCount?.getD 0
      saveReady := saveReady?.getD true
      saveReadyReason := saveReadyReason?.getD "ok"
      saveReadyMessage?
      blockingDiagnostics := blockingDiagnostics?.getD #[]
      blockingCommandMessages := blockingCommandMessages?.getD #[]
    }

end RunAt.Internal
