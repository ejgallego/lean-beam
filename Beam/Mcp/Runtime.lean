/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Config
import Beam.Mcp.Protocol

open Lean

namespace Beam.Mcp.Runtime

structure Options where
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  beamCli? : Option String := none

private structure LeanRuntimeConfig where
  leanCmd : String
  leanPlugin : System.FilePath

def setupError (message : String) : RpcError :=
  RpcError.invalidRequest s!"could not set up Lean Beam MCP runtime: {message}"

private def processOutputSummary (stdout stderr : String) : String :=
  let stderr := stderr.trimAscii.toString
  let stdout := stdout.trimAscii.toString
  if !stderr.isEmpty then
    stderr
  else if !stdout.isEmpty then
    stdout
  else
    "(no output)"

private def parseCliMcpConfig (text : String) : Except String LeanRuntimeConfig := do
  let json ← Json.parse text
  let leanCmd ← json.getObjValAs? String "lean_cmd"
  let leanPluginText ← json.getObjValAs? String "lean_plugin"
  pure { leanCmd, leanPlugin := System.FilePath.mk leanPluginText }

private def resolveFromBeamCli (beamCli : String) (root : System.FilePath) : IO (Except String LeanRuntimeConfig) := do
  let out ← IO.Process.output {
    cmd := beamCli
    args := #["--root", root.toString, "mcp-config"]
  }
  if out.exitCode != 0 then
    pure <| .error s!"{beamCli} --root {root} mcp-config failed: {processOutputSummary out.stdout out.stderr}"
  else
    match parseCliMcpConfig out.stdout with
    | .error err => pure <| .error s!"{beamCli} mcp-config returned invalid JSON: {err}"
    | .ok config => do
        let plugin ← IO.FS.realPath config.leanPlugin
        pure <| .ok { config with leanPlugin := plugin }

private def resolveLeanRuntime (opts : Options) (root : System.FilePath) : IO (Except RpcError LeanRuntimeConfig) := do
  let explicitPlugin? ←
    try
      opts.leanPlugin?.mapM (fun path => IO.FS.realPath <| System.FilePath.mk path)
    catch e =>
      return .error <| setupError s!"--lean-plugin does not resolve to a file: {e}"
  match opts.leanCmd?, explicitPlugin? with
  | some leanCmd, some leanPlugin =>
      pure <| .ok { leanCmd, leanPlugin }
  | _, _ =>
      match opts.beamCli? with
      | none =>
          pure <| .error <| setupError
            "use the installed lean-beam-mcp wrapper, pass --beam-cli PATH, or pass both --lean-cmd CMD and --lean-plugin PATH"
      | some beamCli =>
          match ← resolveFromBeamCli beamCli root with
          | .error err => pure <| .error <| setupError err
          | .ok resolved =>
              pure <| .ok {
                leanCmd := opts.leanCmd?.getD resolved.leanCmd
                leanPlugin := explicitPlugin?.getD resolved.leanPlugin
              }

def mkBrokerConfig (opts : Options) (root : System.FilePath) : IO (Except RpcError Beam.Broker.BrokerConfig) := do
  let root ←
    try
      IO.FS.realPath root
    catch e =>
      return .error <| setupError s!"project root does not resolve: {e}"
  let runtime ← resolveLeanRuntime opts root
  match runtime with
  | .error err => pure <| .error err
  | .ok runtime =>
      pure <| .ok {
        root := root
        leanCmd? := some runtime.leanCmd
        leanPlugin? := some runtime.leanPlugin
      }

end Beam.Mcp.Runtime
