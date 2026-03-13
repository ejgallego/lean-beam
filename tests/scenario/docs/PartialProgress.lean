import Lean

open Lean Elab Command

elab "progress_sleep_cmd" : command => do
  IO.sleep 1500

def partialProgressAnchor : Nat := 0

progress_sleep_cmd

def partialProgressDone : Nat := partialProgressAnchor + 1
