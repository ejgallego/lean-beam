# Beam Roadmap Cards

This folder tracks Beam roadmap work as short cards. A card is a reviewable
unit of product or upstream work: one problem, one current decision, and one
clear ownership boundary.

`docs/STATUS.md` remains the user-facing status and release posture. These
cards are maintainer planning material for turning feedback into scoped work.

## Card Sets

| Prefix | Meaning |
| --- | --- |
| `BUC` | Imported Beam upstream cards originally collected from downstream LIRIS work. |
| `ULC` | Upstream Lean cards: Lean or Lake API gaps that would let Beam delete local workarounds or expose cleaner behavior. |

Raw LIRIS evidence payloads are not copied into this public repository. Keep
request/response traces, project-specific source snippets, logs, and local paths
in the originating project until they are sanitized for a public Beam issue.
When a card maps to an existing Beam GitHub issue, link that issue in the card
instead of opening a duplicate.
For upstream Lean cards, keep a `Lean PR` field so accepted or proposed
`leanprover/lean4` changes can be linked without opening duplicate Beam issues.

## 0.2.0 Sorting

The tentative 0.2.0 release theme is actionable failures and reliable recovery,
not adding a large public surface.

### Candidate 0.2.0 Cards

- [BUC-0001 stale import dependency reporting](cards/BUC-0001-stale-import-dependency-reporting/README.md)
- [BUC-0004 runAt diagnostic origin mapping](cards/BUC-0004-runat-diagnostic-origin/README.md)
- [BUC-0006 cold start and daemon lifecycle](cards/BUC-0006-cold-start-daemon-lifecycle/README.md)
- [ULC-0001 structured stale dependency metadata](cards/ULC-0001-structured-stale-dependency-metadata/README.md)
- [ULC-0002 backend readiness primitive](cards/ULC-0002-backend-readiness-primitive/README.md)

### Close Or Archive Candidates

- [BUC-0002 internal exception for tactic-position term ascription](cards/BUC-0002-internal-exception-runat-term-ascription/README.md)
- [BUC-0008 agent feedback card API](cards/BUC-0008-agent-feedback-card-api/README.md)

### Deferred Candidates

- [BUC-0003 handle continuation state](cards/BUC-0003-handle-continuation-state/README.md)
- [BUC-0005 diagnostics, todo, and progress metadata](cards/BUC-0005-diagnostics-todo-progress/README.md)
- [BUC-0007 save and refresh batching](cards/BUC-0007-save-refresh-batching/README.md)
- [ULC-0003 structured file-worker progress](cards/ULC-0003-structured-file-worker-progress/README.md)
- [ULC-0004 structured Lean request error data](cards/ULC-0004-structured-lean-request-error-data/README.md)
- [ULC-0005 pure frontend readiness report](cards/ULC-0005-pure-frontend-readiness-report/README.md)
- [ULC-0006 compatibility shim retirement](cards/ULC-0006-compatibility-shim-retirement/README.md)

## Card Rules

- One card owns one roadmap question.
- Keep the top-level card short enough to paste into an issue or PR.
- Record reproduction status separately from proposed fixes.
- Link sanitized public evidence when available; do not paste private project traces.
- Search existing open Beam issues before filing a new issue for a card.
- For `ULC` cards, link an upstream Lean PR when one exists.
- Prefer deleting Beam workarounds when upstream Lean support makes them obsolete.
- Move a card to close/archive only after retesting or replacing it with a narrower card.
