example : True := by induction 1 with
                                --^ $/lean/runAt: {"text":"exact trivial"}

example : True := by induction 1 with |
                                --^ $/lean/runAt: {"text":"exact trivial"}

example : True := by induction 1 with done
                                --^ $/lean/runAt: {"text":"exact trivial"}
