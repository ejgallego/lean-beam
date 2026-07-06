/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.DocumentState

open Lean

namespace Beam.Broker

/--
Data used by the supported sync/readiness path to explain stale direct dependencies after a failed
diagnostics barrier.

This is intentionally scoped to the sync/readiness recovery path rather than exposed as a standalone
dependency-inspection surface.
-/

structure StaleDirectDepHint where
  module : String
  path : String
  needsSave : Bool
  deriving Inhabited

def staleDirectDepHintJson (hint : StaleDirectDepHint) : Json :=
  Json.mkObj [
    ("module", toJson hint.module),
    ("path", toJson hint.path),
    ("needsSave", toJson hint.needsSave)
  ]

def staleSyncErrorData
    (targetPath : String)
    (hints : Array StaleDirectDepHint)
    (completionBlockingDiagnostics : Array SyncBlockingDiagnostic := #[]) : Json :=
  let saveHints := hints.filter (·.needsSave)
  let recoveryPlan :=
    (saveHints.map fun hint => s!"lean-beam save \"{hint.path}\"") ++
    #[s!"lean-beam refresh \"{targetPath}\"", "lake build"]
  Json.mkObj [
    ("targetPath", toJson targetPath),
    ("staleDirectDeps", Json.arr <| hints.map staleDirectDepHintJson),
    ("saveDeps", Json.arr <| saveHints.map (fun hint => toJson hint.path)),
    ("completionBlockingDiagnostics", toJson completionBlockingDiagnostics),
    ("recoveryPlan", Json.arr <| recoveryPlan.map toJson)
  ]

def collectStaleDirectDepHints
    (imports : Array String)
    (targetLastSyncEventSeq : Nat)
    (history : DocumentState.ModuleHistories)
    : Array StaleDirectDepHint :=
  imports.foldl (init := #[]) fun hints moduleName =>
    match history.get? moduleName with
    | some moduleHistory =>
        if moduleHistory.lastTextChangeEventSeq > targetLastSyncEventSeq ||
            moduleHistory.lastSaveEventSeq > targetLastSyncEventSeq then
          hints.push {
            module := moduleName
            path := moduleHistory.path
            needsSave := moduleHistory.lastSaveEventSeq < moduleHistory.lastTextChangeEventSeq
          }
        else
          hints
    | none =>
        hints

end Beam.Broker
