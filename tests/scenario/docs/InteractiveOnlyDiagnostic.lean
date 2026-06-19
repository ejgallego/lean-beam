import Lean

open Lean Elab Command

elab "#beam_interactive_only_error" : command => do
  unless Lean.Elab.inServer.get (← getOptions) do
    return
  let ref ← getRef
  let cancelTk ← IO.CancelToken.new
  let act ← wrapAsyncAsSnapshot (cancelTk? := cancelTk)
    (desc := "beam interactive-only diagnostic fixture") fun (_ : Unit) => do
      logErrorAt ref "interactive-only diagnostic from child snapshot"
  let task ← BaseIO.asTask (act ())
  logSnapshotTask {
    stx? := none
    reportingRange := .skip
    task
    cancelTk? := cancelTk
  }

#beam_interactive_only_error

def interactiveOnlyValue : Nat := 1
