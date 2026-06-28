def dependentValue : Nat := by
  -- The scenario test edits this value proof without editing the theorem below.
    exact 0
example : dependentValue = 0 := by
    rfl
