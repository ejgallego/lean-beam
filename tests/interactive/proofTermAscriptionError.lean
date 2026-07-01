example : ∀ (n : Nat), n = n := by
  intro x
--v $/lean/runAt: {"text":"have htest := (Nat.succ : Nat)"}
  exact rfl
