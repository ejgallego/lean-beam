import Lean

open Lean Elab Tactic

private partial def spinTacticUntilCancelled : TacticM Unit := do
  evalTactic (← `(tactic| sleep 30))
  if let some tk := (← readThe Core.Context).cancelTk? then
    if ← tk.isSet then
      throwInterruptException
  spinTacticUntilCancelled

elab "poll_sleep_tac" : tactic => do
  spinTacticUntilCancelled

example : True ∧ True := by
