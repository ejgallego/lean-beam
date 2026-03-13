example : And (And True True) True := by
  constructor
  · constructor
    · trivial
    · trivial
  · --
   --^ $/lean/runAt: {"text":"exact trivial"}
