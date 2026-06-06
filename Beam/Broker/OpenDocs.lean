/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Deps
import Beam.Broker.DocumentState
import Beam.Broker.LakeSave
import Beam.Broker.Protocol

open Lean
open Lean.Lsp

namespace Beam.Broker
namespace OpenDocs

structure SessionView where
  backend : Backend
  root : System.FilePath
  docs : DocumentState.Docs := {}

def docSyncStatus (path : System.FilePath) (docState : DocState) : IO String := do
  if !(← path.pathExists) then
    pure "missing"
  else
    let text ← IO.FS.readFile path
    pure <| if hash text == docState.textHash then "saved" else "notSaved"

private def docDepsJson? (root : System.FilePath) (path : System.FilePath) (uri : DocumentUri) :
    IO (Option Json) := do
  let some module := normalizeModuleForPath root path uri none
    | pure none
  try
    let state ← mkDepsQueryState root
    let imports ← requireDirectImports state module.name
    pure <| some <| Json.arr <| imports.map (importJson root)
  catch _ =>
    pure none

private def docSaveFields
    (root : System.FilePath)
    (backend : Backend)
    (path? : Option System.FilePath)
    (leanCmd? : Option String) : IO (List (String × Json)) := do
  match backend, path? with
  | .lean, some path =>
      match ← checkLeanSaveTarget root path leanCmd? with
      | .eligible moduleName =>
          pure [
            ("saveEligible", toJson true),
            ("saveReason", toJson "ok"),
            ("saveModule", toJson moduleName.toString)
          ]
      | .notModule =>
          pure [
            ("saveEligible", toJson false),
            ("saveReason", toJson saveTargetNotModuleCode)
          ]
      | .workspaceLoadFailed msg =>
          pure [
            ("saveEligible", toJson false),
            ("saveReason", toJson "workspaceLoadFailed"),
            ("saveDetail", toJson msg)
          ]
  | _, _ =>
      pure []

def docJson
    (root : System.FilePath)
    (backend : Backend)
    (leanCmd? : Option String)
    (uri : DocumentUri)
    (docState : DocState) : IO Json := do
  let path? := System.Uri.fileUriToPath? uri
  let relPath? := workspacePath? root uri
  let status ←
    match path? with
    | some path => docSyncStatus path docState
    | none => pure "unknown"
  let saved := status == "saved"
  let savedOlean := saved && docState.savedOleanVersion? == some docState.version
  let depsFields ←
    match backend, path? with
    | .lean, some path =>
        match ← docDepsJson? root path uri with
        | some deps => pure [("deps", deps)]
        | none => pure []
    | _, _ => pure []
  let fileProgressFields :=
    match docState.fileProgress? with
    | some fileProgress => [("fileProgress", toJson fileProgress)]
    | none => []
  let saveFields ← docSaveFields root backend path? leanCmd?
  pure <| Json.mkObj <|
    [
      ("uri", toJson uri),
      ("version", toJson docState.version),
      ("status", toJson status),
      ("saved", toJson saved),
      ("savedOlean", toJson savedOlean)
    ] ++
    (match relPath?, path? with
    | some relPath, _ => [("path", toJson relPath)]
    | none, some path => [("path", toJson path.toString)]
    | none, none => []) ++
    depsFields ++
    saveFields ++
    fileProgressFields

def sessionJson (leanCmd? : Option String) (session? : Option SessionView) : IO Json := do
  match session? with
  | none =>
      pure <| Json.mkObj [
        ("active", toJson false),
        ("files", Json.arr #[])
      ]
  | some session =>
      let files ← session.docs.toList.mapM fun (uri, docState) =>
        docJson session.root session.backend leanCmd? uri docState
      pure <| Json.mkObj [
        ("active", toJson true),
        ("files", Json.arr files.toArray)
      ]

def payload
    (root : System.FilePath)
    (leanCmd? : Option String)
    (leanSession? : Option SessionView)
    (rocqSession? : Option SessionView) : IO Json := do
  pure <| Json.mkObj [
    ("root", toJson root.toString),
    ("sessions", Json.mkObj [
      ("lean", ← sessionJson leanCmd? leanSession?),
      ("rocq", ← sessionJson leanCmd? rocqSession?)
    ])
  ]

end OpenDocs
end Beam.Broker
