/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Lean

namespace Beam.Broker

def invalidParamsResponse (message : String) : Response :=
  reqError "invalidParams" message

private def asInvalidParams (arg : Except String α) : Except Response α :=
  arg.mapError invalidParamsResponse

def Request.rootArg (req : Request) : Except Response System.FilePath :=
  asInvalidParams req.requireRoot

def Request.pathArg (req : Request) : Except Response System.FilePath :=
  asInvalidParams req.requirePath

def Request.cancelRequestIdArg (req : Request) : Except Response String :=
  asInvalidParams req.requireCancelRequestId

structure PositionArgs where
  path : System.FilePath
  version : Nat
  line : Nat
  character : Nat

def Request.positionArgs (req : Request) : Except Response PositionArgs := do
  let path ← asInvalidParams req.requirePath
  let version ← asInvalidParams req.requireVersion
  let line ← asInvalidParams req.requireLine
  let character ← asInvalidParams req.requireCharacter
  pure { path, version, line, character }

structure RunAtArgs extends PositionArgs where
  text : String
  method : String

def Request.runAtArgs (req : Request) : Except Response RunAtArgs := do
  let position ← req.positionArgs
  let text ← asInvalidParams req.requireText
  let method ← asInvalidParams (runAtMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    text
    method
  }

structure RequestAtArgs extends PositionArgs where
  method : String
  extraParams : Lean.Json

def Request.requestAtArgs (req : Request) : Except Response RequestAtArgs := do
  let position ← req.positionArgs
  let requestedMethod ← asInvalidParams req.requireMethod
  let method ← asInvalidParams (requestAtMethod req.backend requestedMethod)
  let extraParams ← asInvalidParams req.requireParamsObject
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    method
    extraParams
  }

structure GoalsArgs extends PositionArgs where
  method : String

def Request.goalsArgs (req : Request) : Except Response GoalsArgs := do
  let position ← req.positionArgs
  let method ← asInvalidParams (goalsMethod req.backend req.mode?)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    method
  }

structure TodoArgs extends PositionArgs where
  endLine : Nat
  endCharacter : Nat
  method : String

def Request.todoArgs (req : Request) : Except Response TodoArgs := do
  let position ← req.positionArgs
  let endLine ← asInvalidParams req.requireEndLine
  let endCharacter ← asInvalidParams req.requireEndCharacter
  let method ← asInvalidParams (todoMethod req.backend)
  pure {
    path := position.path
    version := position.version
    line := position.line
    character := position.character
    endLine
    endCharacter
    method
  }

structure RunWithArgs where
  path : System.FilePath
  handle : Handle
  text : String
  method : String

def Request.runWithArgs (req : Request) : Except Response RunWithArgs := do
  let path ← asInvalidParams req.requirePath
  let handle ← asInvalidParams req.requireHandle
  let text ← asInvalidParams req.requireText
  let method ← asInvalidParams (runWithMethod req.backend)
  pure { path, handle, text, method }

structure ReleaseArgs where
  path : System.FilePath
  handle : Handle
  method : String

def Request.releaseArgs (req : Request) : Except Response ReleaseArgs := do
  let path ← asInvalidParams req.requirePath
  let handle ← asInvalidParams req.requireHandle
  let method ← asInvalidParams (releaseMethod req.backend)
  pure { path, handle, method }

end Beam.Broker
