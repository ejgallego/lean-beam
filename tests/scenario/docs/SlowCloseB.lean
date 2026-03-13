import Lean

open Lean Elab Tactic

-- Keep the proof tactic on line 9 for existing scenario positions.

example : True := by
  sleep 2000
  trivial
