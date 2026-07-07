# BUC-0003 Handle Continuation State

Status: deferred
Kind: ux
Priority: high
Origin: LIRIS
Last reviewed: 2026-07-07
Issue: none linked

## Summary

Beam handles are useful for proofmode work, but agents still need clearer
metadata around open theorem commands, branch focus, and sibling-goal
continuation. Some probes produce useful goals but no handle, and some linear
continuations can close a focused branch while making sibling-goal state hard
to classify.

## Impact

- A result with `goals: []` and a new handle can be ambiguous to agents.
- Proofmode metadata such as `userName` may not be meaningful enough for
  agent-facing decisions.
- It is hard to know whether a child handle can continue all goals or only the
  focused branch.

## Beam Decision

Defer for 0.2.0 unless it blocks a concrete release workflow. Handles are real
and useful, but they remain alpha support APIs around the core `runAt` request.
The 0.2.0 focus should stay on actionable failures and recovery.

## Expected Behavior

Handle responses should expose enough state for an agent to know whether it can
continue all goals:

```json
{
  "goalCount": 2,
  "focusedGoalCount": 1,
  "siblingGoalCount": 1,
  "handleCanContinueAllGoals": true,
  "handleFocusMode": "allGoals"
}
```

If Beam cannot retain a handle for an open theorem command, return a structured
reason such as `openTheoremCommandRejectedByLean` with `goalsAvailable: true`.

## Evidence

Imported from the LIRIS card set. Raw proofmode traces were not copied into
this public repository.

## Current Workaround

Use handles for small one-step proof-state exploration. For branch closure,
write a saved reduced theorem with bullets and validate with `lean_sync` /
`lean_save` before treating the proof as landed.
