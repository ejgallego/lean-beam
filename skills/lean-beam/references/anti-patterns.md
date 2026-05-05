# Lean Agent Anti-Patterns

Use this reference as a short checklist of what not to assume in Lean `beam` workflows.

## Do Not Assume

- one `lean-beam run-at` call automatically changes the basis of the next one
- `lean-beam run-at` edits the file or creates a new saved baseline
- `lean-beam run-at` implies a full-file diagnostics barrier
- `lean-beam run-at` fills indentation, inserts missing newlines, or reformats text for you
- `lean-beam sync` recovers speculative text that you never wrote into the file
- `lean-beam save` is valid for any `.lean` file the daemon can open
- a downstream probe is trustworthy right after editing an imported dependency
- wrapper `stderr` is the machine-readable surface
- creating a `/tmp` scratch Lean file for a question that belongs at a real source position
- batching unrelated proof attempts into one scratch file just to amortize Lean startup
- treating a detached scratch file success as equivalent to success in the workspace module context

## Prefer Instead

- use `lean-beam hover` for existing semantic info
- use `lean-beam goals-prev` / `lean-beam goals-after` for existing proof state
- use `lean-beam run-at` for one speculative snippet on the current saved file snapshot
- probe at the real source position with `lean-beam run-at`
- pass multiline speculative text with `--stdin` instead of writing a temporary Lean file
- use `lean-beam run-at-handle` plus `lean-beam run-with` / `lean-beam run-with-linear` for exact speculative chaining
- use a real edit, save, then `lean-beam sync` when the speculative result should become source
- use `lean-beam save` only for a synced workspace module
- use `beam-client request-stream` for machine-readable streaming diagnostics or progress
- use `lake build` when the task has become dependency freshness or final validation
