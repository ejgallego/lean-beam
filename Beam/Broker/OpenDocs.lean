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

inductive DiskStatus where
  | saved
  | notSaved
  | missing
  | unknown
  deriving BEq

def DiskStatus.key : DiskStatus → String
  | .saved => "saved"
  | .notSaved => "notSaved"
  | .missing => "missing"
  | .unknown => "unknown"

instance : ToJson DiskStatus where
  toJson status := toJson status.key

def docDiskStatus (path : System.FilePath) (docState : DocState) : IO DiskStatus := do
  if !(← path.pathExists) then
    pure .missing
  else
    let text ← IO.FS.readFile path
    pure <| if hash text == docState.textHash then .saved else .notSaved

def docJson
    (root : System.FilePath)
    (uri : DocumentUri)
    (docState : DocState) : IO Json := do
  let path? := System.Uri.fileUriToPath? uri
  let relPath? := path?.bind (Beam.pathRelativeToRoot? root)
  let status ←
    match path? with
    | some path => docDiskStatus path docState
    | none => pure .unknown
  let checkpointed :=
    status == .saved && docState.checkpointedVersion? == some docState.version
  let fileProgressFields :=
    match docState.fileProgress? with
    | some fileProgress => [("fileProgress", toJson fileProgress)]
    | none => []
  pure <| Json.mkObj <|
    [
      ("uri", toJson uri),
      ("version", toJson docState.version),
      ("status", toJson status),
      ("checkpointed", toJson checkpointed)
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
