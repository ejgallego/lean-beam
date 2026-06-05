/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Protocol

namespace Beam.Mcp

def runtimeSetupErrorPrefix : String :=
  "could not set up Lean Beam MCP runtime"

def runtimeSetupGuidance : String :=
  "use the installed lean-beam-mcp wrapper, pass --beam-cli PATH, or pass both --lean-cmd CMD and --lean-plugin PATH"

def projectRootSetupError (detail : String) : String :=
  s!"project root does not resolve: {detail}"

def leanPluginSetupError (detail : String) : String :=
  s!"--lean-plugin does not resolve to a file: {detail}"

def runtimeSetupError (message : String) : RpcError :=
  RpcError.invalidRequest s!"{runtimeSetupErrorPrefix}: {message}"

end Beam.Mcp
