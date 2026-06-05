/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Daemon

namespace RunAtTest.Broker.CliDaemonTest

private def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

private def checkStartupRetryPolicy : IO Unit := do
  require "automatic occupied endpoint should retry"
    (Beam.Cli.shouldRetryAutomaticStartup true 1 true)
  require "automatic endpoint should not retry after attempts are exhausted"
    (!Beam.Cli.shouldRetryAutomaticStartup true 0 true)
  require "automatic endpoint should not retry when endpoint is not occupied after failure"
    (!Beam.Cli.shouldRetryAutomaticStartup true 1 false)
  require "explicit endpoint should not retry"
    (!Beam.Cli.shouldRetryAutomaticStartup false 1 true)

def main : IO Unit := do
  checkStartupRetryPolicy

end RunAtTest.Broker.CliDaemonTest

def main := RunAtTest.Broker.CliDaemonTest.main
