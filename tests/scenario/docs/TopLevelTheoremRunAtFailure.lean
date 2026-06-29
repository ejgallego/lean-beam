import Lean

open Lean Elab Tactic

elab "runat_fail_tac" : tactic => do
  throwError "runAt custom tactic failure"

theorem runAtFailureBasis : True := by
  trivial
