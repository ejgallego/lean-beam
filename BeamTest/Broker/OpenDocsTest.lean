/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.OpenDocs
import BeamTest.Broker.JsonAssert

open Lean
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.OpenDocsTest

private def requireArray (label : String) (json : Json) : IO (Array Json) := do
  match json with
  | .arr values => pure values
  | _ => throw <| IO.userError s!"{label}: expected array, got {json.compress}"

private def mkDoc (text : String) (version : Nat := 1) : DocState := {
  version
  textHash := hash text
  textTraceHash := default
  textMTime := default
}

private def checkInactivePayload : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  let payload ← OpenDocs.payload root none none none
  requireJsonString "open docs payload" "root" root.toString payload
  let sessions ← requireObjVal "open docs payload" "sessions" payload
  let leanSession ← requireObjVal "open docs sessions" "lean" sessions
  let rocqSession ← requireObjVal "open docs sessions" "rocq" sessions
  requireJsonBool "inactive lean session" "active" false leanSession
  requireJsonBool "inactive rocq session" "active" false rocqSession
  require "inactive lean session has empty files"
    ((← requireArray "inactive lean files" (← requireObjVal "inactive lean session" "files" leanSession)).isEmpty)
  require "inactive rocq session has empty files"
    ((← requireArray "inactive rocq files" (← requireObjVal "inactive rocq session" "files" rocqSession)).isEmpty)

private def checkRocqDocProjection : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-open-docs-test-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  let path := root / "Demo.v"
  let text := "Check nat.\n"
  IO.FS.writeFile path text
  let uri := (System.Uri.pathToUri path : String)
  let docs : DocumentState.Docs :=
    Std.TreeMap.empty.insert uri {
      (mkDoc text 2) with
      fileProgress? := some { updates := 3, done := true }
    }
  let session : OpenDocs.SessionView := {
    backend := .rocq
    root
    docs
  }
  let sessionJson ← OpenDocs.sessionJson none (some session)
  requireJsonBool "open docs active session" "active" true sessionJson
  let files ← requireArray "open docs files" (← requireObjVal "open docs active session" "files" sessionJson)
  require "open docs active session has one file" (files.size == 1)
  let file := files[0]!
  requireJsonString "open docs file" "uri" uri file
  requireJsonString "open docs file" "path" "Demo.v" file
  requireJsonString "open docs file" "status" "saved" file
  requireJsonBool "open docs file" "saved" true file
  requireJsonBool "open docs file" "savedOlean" false file
  discard <| requireObjVal "open docs file" "fileProgress" file

def main : IO Unit := do
  checkInactivePayload
  checkRocqDocProjection

end BeamTest.Broker.OpenDocsTest

def main := BeamTest.Broker.OpenDocsTest.main
