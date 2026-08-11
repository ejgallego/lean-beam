/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.DocumentState
import Beam.Broker.Protocol
import Beam.Path

open Lean
open Lean.Lsp

namespace Beam.Broker
namespace OpenDocs

structure SessionView where
  root : System.FilePath
  docs : DocumentState.Docs := {}

def docSyncStatus (path : System.FilePath) (docState : DocState) : IO String := do
  if !(← path.pathExists) then
    pure "missing"
  else
    let text ← IO.FS.readFile path
    pure <| if hash text == docState.textHash then "saved" else "notSaved"

def docJson
    (root : System.FilePath)
    (uri : DocumentUri)
    (docState : DocState) : IO Json := do
  let path? := System.Uri.fileUriToPath? uri
  let relPath? := Beam.pathRelativeToRootFromUri? root uri
  let status ←
    match path? with
    | some path => docSyncStatus path docState
    | none => pure "unknown"
  let saved := status == "saved"
  let savedOlean := saved && docState.savedOleanVersion? == some docState.version
  let fileProgressFields :=
    match docState.fileProgress? with
    | some fileProgress => [("fileProgress", toJson fileProgress)]
    | none => []
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
    fileProgressFields

def sessionJson (session? : Option SessionView) : IO Json := do
  match session? with
  | none =>
      pure <| Json.mkObj [
        ("active", toJson false),
        ("files", Json.arr #[])
      ]
  | some session =>
      let files ← session.docs.toList.mapM fun (uri, docState) =>
        docJson session.root uri docState
      pure <| Json.mkObj [
        ("active", toJson true),
        ("files", Json.arr files.toArray)
      ]

def payload
    (root : System.FilePath)
    (leanSession? : Option SessionView)
    (rocqSession? : Option SessionView) : IO Json := do
  pure <| Json.mkObj [
    ("root", toJson root.toString),
    ("sessions", Json.mkObj [
      ("lean", ← sessionJson leanSession?),
      ("rocq", ← sessionJson rocqSession?)
    ])
  ]

end OpenDocs
end Beam.Broker
