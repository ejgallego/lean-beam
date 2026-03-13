example : (True ∧ True) ∧ (True ∧ True) := by
--v $/lean/runAt: {"text":"constructor"}
  constructor
  ·
--v $/lean/runAt: {"text":"constructor"}
    constructor
             --^ $/lean/runAt: {"text":"exact trivial"}
    · trivial
    · trivial
  · trivial
