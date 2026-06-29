/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.LSP.Lib.NativeLib

open Lean

namespace Beam.Cli

structure InstallLayout where
  rootFiles : List String
  sourceDirs : List String
  runtimePaths : List String
  wrapperPaths : List String
  sourceHashInputs : List String
  deriving ToJson

def bundleRootFiles : List String :=
  ["Beam.lean", "lakefile.lean", "lakefile.toml", "lake-manifest.json", "lean-toolchain",
    "supported-lean-toolchains", "custom-lean-toolchains"]

def bundleSourceDirs : List String :=
  ["Beam"]

def bundleSourceHashInputLabels : List String :=
  bundleRootFiles ++ bundleSourceDirs.map (· ++ "/**")

def installRuntimePaths : List String :=
  ["libexec/beam-cli", "libexec/beam-daemon", "libexec/beam-client",
    "libexec/lean-beam-mcp", s!"libexec/{Beam.LSP.Lib.pluginSharedLibName}", ".lake/packages"]

def installWrapperPaths : List String :=
  ["bin/lean-beam", "bin/lean-beam-search", "bin/lean-beam-mcp"]

def installLayout : InstallLayout :=
  {
    rootFiles := bundleRootFiles
    sourceDirs := bundleSourceDirs
    runtimePaths := installRuntimePaths
    wrapperPaths := installWrapperPaths
    sourceHashInputs := bundleSourceHashInputLabels
  }

def installManifestJson (payloadHash : String) (sourceCommit? : Option String) (toolchains : List String) :
    Json :=
  Json.mkObj [
    ("schemaVersion", toJson (2 : Nat)),
    ("payloadHash", toJson payloadHash),
    ("toolchains", toJson toolchains),
    ("sourceCommit", sourceCommit?.map toJson |>.getD Json.null),
    ("artifacts", toJson installLayout)
  ]

end Beam.Cli
