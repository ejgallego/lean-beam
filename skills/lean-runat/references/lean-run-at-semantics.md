# Lean Run-At Semantics

Use this reference when a task is confused about what `lean-run-at` means. The short rule is:
`lean-run-at` is a speculative execution probe against one saved file snapshot, not a source edit.

## What It Is Not

- it is not an edit to the file on disk
- it is not a full-file diagnostics barrier
- it is not implicit continuation from one speculative probe to the next
- it is not an indentation or whitespace synthesizer
- it does not insert missing `\n` separators or rewrite one-line text into a multi-line edit for you

## 1. Expecting Full-File Diagnostics After A Speculative Probe

Wrong expectation:

```bash
runat lean-run-at "Foo.lean" 20 2 "exact h"
# then expect diagnostics for unrelated later declarations as if Foo.lean had been edited
```

Correct workflow:

```bash
# make the real edit in Foo.lean and save it to disk
runat lean-sync "Foo.lean"
```

Use `lean-sync` when you need diagnostics for the saved file version as a whole. `lean-run-at`
only waits for the snapshot needed by that speculative request.

If the speculative probe looks right and you want to keep it, open
[commit-speculative.md](commit-speculative.md).

## 2. Expecting One Probe To Become The Basis Of The Next

Wrong expectation:

```bash
runat lean-run-at "Foo.lean" 30 2 "tac1"
runat lean-run-at "Foo.lean" 30 2 "tac2"
# then expect the second call to continue from the speculative `tac1`
```

Correct workflow:

```bash
root="$(runat lean-run-at-handle "Foo.lean" 30 2 "tac1")"
printf '%s\n' "$root" | runat lean-run-with-linear "Foo.lean" - "tac2"
```

Use a handle when exact speculative continuation matters. Separate `lean-run-at` calls do not share
hidden mutable proof state.

If the task is branching or doing playouts, also open
[mcts-search.md](mcts-search.md).

If a speculative step looks right and you want it to become real source, open
[commit-speculative.md](commit-speculative.md).

## 3. Expecting Indentation Or Newlines To Be Filled Automatically

Wrong expectation:

```bash
runat lean-run-at "Foo.lean" 18 0 "exact h"
# where line 18 is a blank line inside an indented block, and expect the wrapper to infer indentation
#
# or expect the wrapper to add a leading/trailing newline around the text automatically
```

Correct workflow:

```bash
# on a truly empty line, only column 0 is valid, so provide the indentation in the text yourself
runat lean-run-at "Foo.lean" 18 0 "    exact h"

# or probe after the existing indentation and pass only the code text
runat lean-run-at "Foo.lean" 18 4 "exact h"
```

Or make the real edit in the file and save it before syncing:

```bash
# edit Foo.lean so the tactic is written with the indentation you want
runat lean-sync "Foo.lean"
```

`lean-run-at` uses the text you pass at the position you pass. If layout matters, choose the
position and text together instead of expecting the wrapper to rewrite indentation for you.
On a truly empty line, `18 1` would already be out of range; blank lines are still 0-based Lean/LSP
positions.

If the speculative text is the version you want to keep, open
[commit-speculative.md](commit-speculative.md).

For multi-line probes, include the actual newline characters you want Lean to parse. For example:

```bash
# using ANSI-C shell quoting so `\n` becomes a real newline
runat lean-run-at "Foo.lean" 18 0 $'  first | exact h1\n  | exact h2'
```

Do not expect the wrapper to turn `"first | exact h1 | exact h2"` into a properly line-broken block,
or to add missing `\n` separators around the text.
