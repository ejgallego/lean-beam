/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Git

open Lean

namespace Beam.Version

def projectVersion : String :=
  "0.1.0"

def cliName : String :=
  "lean-beam"

def mcpServerName : String :=
  "lean-beam-mcp"

def mcpProtocolVersion : String :=
  "2025-11-25"

private def optionalField (key : String) (value? : Option String) : List (String × Json) :=
  match value? with
  | some value => [(key, toJson value)]
  | none => []

private def optionalBoolField (key : String) (value? : Option Bool) : List (String × Json) :=
  match value? with
  | some value => [(key, toJson value)]
  | none => []

private def runtimePayload? (home : System.FilePath) : Option String := do
  let parent ← home.parent
  let parentName ← parent.fileName
  if parentName == "versions" then
    home.fileName
  else
    none

private def manifestPath? (home : System.FilePath) : IO (Option System.FilePath) := do
  let path := home / "manifest.json"
  if ← path.pathExists then
    pure (some path)
  else
    pure none

private def manifestSourceCommit? (manifest? : Option System.FilePath) : IO (Option String) := do
  match manifest? with
  | none => pure none
  | some manifest =>
      try
        let json ← IO.ofExcept <| Json.parse (← IO.FS.readFile manifest)
        match json.getObjVal? "sourceCommit" with
        | .ok (.str commit) => pure (some commit)
        | _ => pure none
      catch _ =>
        pure none

structure Identity where
  name : String
  version : String := projectVersion
  mcpProtocol? : Option String := none
  wrapper? : Option String := none
  beamHome? : Option String := none
  beamCli? : Option String := none
  serverBinary? : Option String := none
  runtimePayload? : Option String := none
  manifest? : Option String := none
  sourceCommit? : Option String := none
  sourceBranch? : Option String := none
  sourceDirty? : Option Bool := none
  activeRoot? : Option String := none
  runtimeActive? : Option Bool := none

def Identity.asJson (identity : Identity) : Json :=
  Json.mkObj <|
    [
      ("name", toJson identity.name),
      ("version", toJson identity.version)
    ] ++
    optionalField "mcp_protocol" identity.mcpProtocol? ++
    optionalField "wrapper" identity.wrapper? ++
    optionalField "beam_home" identity.beamHome? ++
    optionalField "beam_cli" identity.beamCli? ++
    optionalField "server_binary" identity.serverBinary? ++
    optionalField "runtime_payload" identity.runtimePayload? ++
    optionalField "manifest" identity.manifest? ++
    optionalField "source_commit" identity.sourceCommit? ++
    optionalField "source_branch" identity.sourceBranch? ++
    optionalBoolField "source_dirty" identity.sourceDirty? ++
    optionalField "active_root" identity.activeRoot? ++
    optionalBoolField "runtime_active" identity.runtimeActive?

def Identity.textLines (identity : Identity) : List String :=
  [s!"{identity.name} {identity.version}"] ++
  (match identity.mcpProtocol? with
  | some protocol => [s!"mcp protocol: {protocol}"]
  | none => []) ++
  (match identity.wrapper? with
  | some wrapper => [s!"wrapper: {wrapper}"]
  | none => []) ++
  (match identity.beamHome? with
  | some home => [s!"beam home: {home}"]
  | none => []) ++
  (match identity.beamCli? with
  | some beamCli => [s!"beam cli: {beamCli}"]
  | none => []) ++
  (match identity.serverBinary? with
  | some serverBinary => [s!"server binary: {serverBinary}"]
  | none => []) ++
  (match identity.beamHome?, identity.runtimePayload? with
  | some _, some payload => [s!"runtime payload: {payload}"]
  | some _, none => [s!"runtime payload: (source tree)"]
  | none, _ => []) ++
  (match identity.beamHome?, identity.manifest? with
  | some _, some manifest => [s!"manifest: {manifest}"]
  | some _, none => [s!"manifest: (none)"]
  | none, _ => []) ++
  (match identity.sourceCommit? with
  | some commit => [s!"source commit: {commit}"]
  | none => []) ++
  (match identity.sourceBranch? with
  | some branch => [s!"source branch: {branch}"]
  | none => []) ++
  (match identity.sourceDirty? with
  | some dirty => [s!"source dirty: {dirty}"]
  | none => []) ++
  (match identity.activeRoot? with
  | some root => [s!"active root: {root}"]
  | none => []) ++
  (match identity.runtimeActive? with
  | some active => [s!"runtime active: {active}"]
  | none => [])

def Identity.text (identity : Identity) : String :=
  String.intercalate "\n" identity.textLines

def mkRuntimeIdentity
    (name : String)
    (home? : Option System.FilePath := none)
    (wrapper? : Option String := none)
    (beamCli? : Option String := none)
    (serverBinary? : Option String := none)
    (mcpProtocol? : Option String := none)
    (activeRoot? : Option System.FilePath := none)
    (runtimeActive? : Option Bool := none) : IO Identity := do
  let manifest? ←
    match home? with
    | some home => manifestPath? home
    | none => pure none
  let manifestCommit? ← manifestSourceCommit? manifest?
  let sourceCommit? ←
    match home?, manifestCommit? with
    | _, some commit => pure (some commit)
    | some home, none => Beam.Git.fullCommitAt? home
    | none, none => pure none
  let sourceBranch? ←
    match home?, manifest? with
    | some home, none => Beam.Git.branchAt? home
    | _, some _ | none, none => pure none
  let sourceDirty? ←
    match home?, manifest? with
    | some home, none => Beam.Git.dirtyAt? home
    | _, some _ | none, none => pure none
  pure {
    name
    mcpProtocol?
    wrapper?
    beamHome? := home?.map (·.toString)
    beamCli?
    serverBinary?
    runtimePayload? := home?.bind runtimePayload?
    manifest? := manifest?.map (·.toString)
    sourceCommit?
    sourceBranch?
    sourceDirty?
    activeRoot? := activeRoot?.map (·.toString)
    runtimeActive?
  }

def mcpServerIdentity
    (home? : Option System.FilePath)
    (beamCli? : Option String)
    (serverBinary? : Option String)
    (activeRoot? : Option System.FilePath := none)
    (runtimeActive? : Option Bool := none)
    (wrapper? : Option String := none) : IO Identity :=
  mkRuntimeIdentity
    mcpServerName
    home?
    (wrapper? := wrapper?)
    (beamCli? := beamCli?)
    (serverBinary? := serverBinary?)
    (mcpProtocol? := some mcpProtocolVersion)
    (activeRoot? := activeRoot?)
    (runtimeActive? := runtimeActive?)

end Beam.Version
