example : True := (by exact True.intro)
                                    --^ $/lean/runAt: {"text":"exact trivial"}

example : True := (by exact True.intro )
                                     --^ $/lean/runAt: {"text":"exact trivial"}
