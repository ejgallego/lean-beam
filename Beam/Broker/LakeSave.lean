/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake.Config.InstallPath
import Lake.Load.Workspace
import Lake.Build.Run
import Lake.Build.Targets
import Lake.Build.Job.Monad
import Lake.Build.Common
import Lake.Build.InitFacets
import Lean.Elab.Term
import Beam.Broker.Config
import Beam.Broker.Errors
import Beam.Broker.LakeEnv
import Beam.Path

open Lean
open System
open Std

namespace Beam.Broker

open Lake

private def moduleOutputIsModuleName : Name :=
  .str (.str (.str .anonymous "Lake") "ModuleOutputDescrs") "isModule"

-- Lake v4.30 added `ModuleOutputDescrs.isModule`; older supported Lake versions do not have it.
-- Select the record shape at elaboration time so save traces work across the supported range.
elab "mkModuleOutputDescrsCompat(" isModule:term ", " olean:term ", " oleanServer:term ", "
    oleanPrivate:term ", " ilean:term ", " ir:term ", " c:term ", " bc:term ")" : term => do
  if (← getEnv).contains moduleOutputIsModuleName then
    Lean.Elab.Term.elabTerm (← `(term| ({
      isModule := $isModule
      olean := $olean
      oleanServer? := $oleanServer
      oleanPrivate? := $oleanPrivate
      ilean := $ilean
      ir? := $ir
      c := $c
      bc? := $bc
    } : ModuleOutputDescrs))) none
  else
    Lean.Elab.Term.elabTerm (← `(term| (
    let _ := $isModule
    {
      olean := $olean
      oleanServer? := $oleanServer
      oleanPrivate? := $oleanPrivate
      ilean := $ilean
      ir? := $ir
      c := $c
      bc? := $bc
    } : ModuleOutputDescrs))) none

structure LeanSaveSpec where
  relPath : String
  moduleName : Name
  unsupportedSetupReason? : Option String := none
  oleanPath : FilePath
  oleanServerPath? : Option FilePath := none
  oleanPrivatePath? : Option FilePath := none
  ileanPath : FilePath
  irPath? : Option FilePath := none
  cPath : FilePath
  bcPath? : Option FilePath := none
  tracePath : FilePath
  depTrace : BuildTrace

structure SourceSnapshot where
  hash : Hash
  mtime : MTime

inductive SaveTargetEligibility where
  | eligible (moduleName : Name)
  | notModule
  | workspaceLoadFailed (message : String)

private def traceOptions (opts : LeanOptions) (caption := "opts") : BuildTrace :=
  opts.values.foldl (init := .nil caption) fun t n v =>
    let opt := s!"-D{n}={v.asCliFlagValue}"
    t.mix <| .ofHash (pureHash opt) opt

-- Lean/Lake v4.28 compatibility shim: newer Lake versions let `addPureTrace` hash any `Hashable`
-- value directly, but v4.28 lacks that generic `ComputeHash` instance. When we drop v4.28 support,
-- replace this helper with the upstream-style `addPureTrace mod.name` / `addPureTrace mod.pkg.id?`.
private def hashOfHashable [Hashable α] (a : α) : Hash :=
  Hash.mix Hash.nil <| Hash.mk <| hash a

private def addHashablePureTrace [ToString α] [Hashable α] (a : α) (caption := "pure") : JobM PUnit :=
  addTrace <| .ofHash (hashOfHashable a) s!"{caption}: {toString a}"

private def unsupportedZeroBuildSaveReason? (mod : Lake.Module) (setup : ModuleSetup) :
    Option String :=
  if !setup.plugins.isEmpty then
    some "Lake module setup loads Lean plugins"
  else if !setup.dynlibs.isEmpty then
    some "Lake module setup loads dynamic libraries"
  else if !setup.options.values.isEmpty then
    some "Lake module setup sets Lean options"
  else if !mod.weakLeanArgs.isEmpty || !mod.leanArgs.isEmpty then
    some "Lake module has custom Lean arguments"
  else
    none

private def quietTraceConfig : BuildConfig :=
  { verbosity := .quiet }

private def sourceTrace (path : FilePath) (snapshot : SourceSnapshot) : BuildTrace :=
  {
    caption := path.toString
    hash := snapshot.hash
    mtime := snapshot.mtime
  }

private def buildDepTraceJob
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : FetchM (Job (BuildTrace × Bool × Option String)) := do
    let setupJob ← mod.setup.fetch
    setupJob.mapM (sync := true) fun setup => do
      addLeanTrace
      addTrace <| sourceTrace mod.leanFile snapshot
      addTrace <| traceOptions setup.options "options"
      addPureTrace setup.isModule "isModule"
      addHashablePureTrace mod.name "Module.name"
      addHashablePureTrace mod.pkg.id? "Package.id?"
      addPureTrace mod.leanArgs "Module.leanArgs"
      setTraceCaption s!"{mod.name.toString}:leanArts"
      return (← getTrace, setup.isModule, unsupportedZeroBuildSaveReason? mod setup)

private def saveTraceStaleMessage (root path : FilePath) : String :=
  let relPath := Beam.pathRelativeToRootOrSelf root path
  s!"Lake save trace is stale for {relPath}. " ++
  "A dependency or build input would need to rebuild before Beam can save this module safely. " ++
  "Save stale direct dependencies with lean-beam save, or run lake build and retry."

private def ensureSaveTraceReady
    (ws : Workspace)
    (root path : FilePath)
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : IO (Except BrokerFailure Unit) := do
  -- Lake's no-build `runBuild` mode is CLI-oriented and may exit the process.
  -- The daemon must convert stale traces into an ordinary request
  -- error before running the trace job for real.
  unless ← ws.checkNoBuild (buildDepTraceJob mod snapshot) do
    return .error {
      code := .saveTraceStale
      message := saveTraceStaleMessage root path
    }
  pure (.ok ())

private def buildDepTrace
    (ws : Workspace)
    (root path : FilePath)
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : IO (Except BrokerFailure (BuildTrace × Bool × Option String)) := do
  match ← ensureSaveTraceReady ws root path mod snapshot with
  | .error failure => pure <| .error failure
  | .ok () =>
      try
        .ok <$> ws.runBuild (cfg := quietTraceConfig) (buildDepTraceJob mod snapshot)
      catch e =>
        pure <| .error {
          code := .internalError
          message := e.toString
        }

def mkLeanSaveSpec
    (root path : FilePath)
    (snapshot : SourceSnapshot)
    (leanCmd? : Option String := none) : IO (Except BrokerFailure LeanSaveSpec) := do
  try
    let root ← Beam.resolveExistingPath root
    let path ← Beam.resolvePathAgainstRoot root path
    let ws ← loadWorkspaceForRoot root leanCmd?
    let some mod := ws.findModuleBySrc? path
      | return .error {
          code := .saveTargetNotModule
          message :=
            s!"could not resolve a Lake module for {path}. " ++
            "lean-beam save only works for synced files that belong to the current Lake workspace package graph."
        }
    let depTraceResult ← buildDepTrace ws root path mod snapshot
    let (depTrace, isModule, unsupportedSetupReason?) ←
      match depTraceResult with
      | .ok result => pure result
      | .error failure => return .error failure
    let relPath := Beam.pathRelativeToRootOrSelf root path
    pure <| .ok {
      relPath
      moduleName := mod.name
      unsupportedSetupReason?
      oleanPath := mod.oleanFile
      oleanServerPath? := if isModule then some mod.oleanServerFile else none
      oleanPrivatePath? := if isModule then some mod.oleanPrivateFile else none
      ileanPath := mod.ileanFile
      irPath? := if isModule then some mod.irFile else none
      cPath := mod.cFile
      bcPath? := if Lean.Internal.hasLLVMBackend () then some mod.bcFile else none
      tracePath := mod.traceFile
      depTrace
    }
  catch e =>
    pure <| .error {
      code := .internalError
      message := e.toString
    }

def checkLeanSaveTarget
    (root path : FilePath)
    (leanCmd? : Option String := none) : IO SaveTargetEligibility := do
  let root ← Beam.resolveExistingPath root
  let path ← Beam.resolvePathAgainstRoot root path
  try
    let ws ← loadWorkspaceForRoot root leanCmd?
    match ws.findModuleBySrc? path with
    | some mod => pure <| .eligible mod.name
    | none => pure .notModule
  catch e =>
    pure <| .workspaceLoadFailed e.toString

private def hashDescr (path : FilePath) (ext : String) : IO ArtifactDescr :=
  return artifactWithExt (← computeHash path) ext

/-- Remove metadata for the prior artifact family before a new family can be published. -/
def invalidateLeanSaveTrace (spec : LeanSaveSpec) : IO Unit := do
  if ← spec.tracePath.isDir then
    throw <| IO.userError s!"Lake save trace path is a directory: {spec.tracePath}"
  if ← spec.tracePath.pathExists then
    IO.FS.removeFile spec.tracePath

def writeLeanSaveTrace (spec : LeanSaveSpec) : IO Unit := do
  let isModule := spec.oleanServerPath?.isSome
  let olean ← hashDescr spec.oleanPath "olean"
  let oleanServer? ← spec.oleanServerPath?.mapM (fun path => hashDescr path "olean.server")
  let oleanPrivate? ← spec.oleanPrivatePath?.mapM (fun path => hashDescr path "olean.private")
  let ilean ← hashDescr spec.ileanPath "ilean"
  let ir? ← spec.irPath?.mapM (fun path => hashDescr path "ir")
  let c ← hashDescr spec.cPath "c"
  let bc? ← spec.bcPath?.mapM (fun path => hashDescr path "bc")
  let outputs : ModuleOutputDescrs :=
    mkModuleOutputDescrsCompat(isModule, olean, oleanServer?, oleanPrivate?, ilean, ir?, c, bc?)
  let pid ← IO.Process.getPID
  let stagedTrace :=
    FilePath.mk s!"{spec.tracePath}.beam-save-trace-tmp-{pid}-{← IO.monoNanosNow}"
  try
    writeBuildTrace stagedTrace spec.depTrace outputs {}
    IO.FS.rename stagedTrace spec.tracePath
  catch e =>
    try
      if ← stagedTrace.pathExists then
        IO.FS.removeFile stagedTrace
    catch _ =>
      pure ()
    throw e

end Beam.Broker
