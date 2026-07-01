/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Scenario

open Lean
open BeamTest.LSP.Scenario

namespace BeamTest.LSP.Handle.Api

def checkRunWithFailureDoesNotStoreHandle : ScenarioM Unit := do
  let cmd ← openDoc "tests/scenario/docs/CommandA.lean"

  -- The scenario DSL cannot currently assert that a failed request did *not* return a handle.
  let mintReq ← sendRunAt cmd { line := 0, character := 2, text := "def tempNoHandle : Nat := 9", storeHandle := true }
  let mint : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) mintReq
  let some handle := mint.handle?
    | throw <| IO.userError "expected command handle"

  let failureReq ← runWithHandle cmd handle {
    text := "#check MissingNameAgain"
    storeHandle := true
    linear := true
  }
  let failure : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) failureReq
  if failure.success then
    throw <| IO.userError "expected semantic failure for failed successor handle test"
  if failure.handle?.isSome then
    throw <| IO.userError "did not expect successor handle on semantic failure"

  closeDoc cmd

def checkRunAtHandleTermAscriptionFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TermAscriptionProof.lean"

  let req ← sendRunAt doc {
    line := 2
    character := 2
    text := "have htest := (Nat.succ : Nat)"
    storeHandle := true
  }
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs (α := Beam.LSP.RunAt.Result) req
  if result.success then
    throw <| IO.userError s!"expected runAt-handle semantic failure, got {(toJson result).compress}"
  if result.handle?.isSome then
    throw <| IO.userError "did not expect handle on failed term-ascription probe"
  unless result.messages.any (fun msg =>
      msg.severity == MessageSeverity.error && msg.text.contains "Type mismatch") do
    throw <| IO.userError
      s!"expected type mismatch diagnostic for term-ascription probe, got {(toJson result).compress}"

  closeDoc doc

def run : ScenarioM Unit := do
  checkRunWithFailureDoesNotStoreHandle
  checkRunAtHandleTermAscriptionFailure

end BeamTest.LSP.Handle.Api
