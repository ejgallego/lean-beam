import Lean

open Lean Elab Tactic

elab "mixed_sleep_exact" : tactic => do
  evalTactic (← `(tactic| sleep 250))
  evalTactic (← `(tactic| exact trivial))

example : True := by
  trivial
