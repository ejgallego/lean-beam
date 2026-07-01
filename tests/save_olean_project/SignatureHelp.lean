def sigTarget (x y : Nat) : Nat :=
  x + y

def sigUse : Nat :=
  sigTarget 1 2
