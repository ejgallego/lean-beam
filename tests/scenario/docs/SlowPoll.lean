import Lean

open Lean Elab Command Tactic

private partial def spinCommandUntilCancelled : CoreM Unit := do
  IO.sleep 30
  Core.checkInterrupted
  spinCommandUntilCancelled

private partial def spinTacticUntilCancelled : TacticM Unit := do
  evalTactic (← `(tactic| sleep 30))
  if let some tk := (← readThe Core.Context).cancelTk? then
    if ← tk.isSet then
      throwInterruptException
  spinTacticUntilCancelled

elab "poll_sleep_cmd" : command => do
  Elab.Command.liftCoreM spinCommandUntilCancelled

elab "poll_sleep_tac" : tactic => do
  spinTacticUntilCancelled

elab "custom_trivial" : tactic => do
  evalTactic (← `(tactic| trivial))

def anchorPoll : Nat := 0

example : True := by
  trivial
