/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Cli

def usage : String :=
  String.intercalate "\n" [
    "usage:",
    "  beam --version",
    "  beam version",
    "  beam [--root PATH] [--port N] ensure [lean|rocq] [--hold]",
    "  beam [--root PATH] [--port N] lean-run-at <path> <version> <line> <character> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--port N] lean-run-at-handle <path> <version> <line> <character> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--port N] lean-hover <path> <version> <line> <character>",
    "  beam [--root PATH] [--port N] lean-signature-help <path> <version> <line> <character>",
    "  beam [--root PATH] [--port N] lean-definition <path> <version> <line> <character>",
    "  beam [--root PATH] [--port N] lean-references <path> <version> <line> <character> [--include-declaration|--exclude-declaration]",
    "  beam [--root PATH] [--port N] lean-document-symbols <path> <version>",
    "  beam [--root PATH] [--port N] lean-workspace-symbols <query...>",
    "  beam [--root PATH] [--port N] lean-goals before|after <path> <version> <line> <character>",
    "  beam [--root PATH] [--port N] lean-todo <path> <version> <startLine> <startCharacter> <endLine> <endCharacter> [--kind <kind> ...] [--suggest none|basic]",
    "  beam [--root PATH] [--port N] lean-run-with <path> <handle-json|-|--handle-file <path>> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--port N] lean-run-with-linear <path> <handle-json|-|--handle-file <path>> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--port N] lean-release <path> <handle-json|-|--handle-file <path>>",
    "  beam [--root PATH] [--port N] lean-update <path>",
    "  beam [--root PATH] [--port N] lean-sync <path> [+full]",
    "  beam [--root PATH] [--port N] lean-refresh <path> [+full]",
    "  beam [--root PATH] [--port N] lean-save <path> [+full]",
    "  beam [--root PATH] [--port N] lean-close <path>",
    "  beam [--root PATH] [--port N] lean-close-save <path> [+full]",
    "  beam [--root PATH] [--port N] rocq-goals-after <path> <line> <character> [text...]",
    "  beam [--root PATH] [--port N] rocq-goals-prev <path> <line> <character> [text...]",
    "  beam [--root PATH] feedback --stdin|--input <path> [--bundle none|dir|zip] [--output-dir <path>] [--no-redact]",
    "  beam bundle-install <toolchain>",
    "  beam supported-toolchains lean",
    "  beam [--root PATH] doctor lean|rocq",
    "  beam [--root PATH] open-files",
    "  beam [--root PATH] cancel <request-id>",
    "  beam [--root PATH] stats",
    "  beam [--root PATH] reset-stats",
    "  beam [--root PATH] shutdown",
    "",
    "Lean edit loop: save the file, then run lean-update for a broker document version.",
    "Run lean-sync when you need the diagnostics/readiness barrier. lean-save is lean-sync plus a",
    "workspace-module checkpoint, lean-refresh is lean-close plus lean-sync, and lean-close-save",
    "adds closing the tracked file afterward.",
    "Run lean-update first, then pass its returned version to Lean position/range/document probes.",
    "Separate lean-run-at calls are independent probes on the broker document version they name.",
    "For exact speculative chaining, use lean-run-at-handle and then lean-run-with /",
    "lean-run-with-linear.",
    "For multiline text-carrying Lean probes, prefer --stdin or --text-file <path>; use -- before",
    "text that itself starts with --.",
    "For handle-based commands, use --handle-file <path> when you do not want to inline handle json.",
    "Use ensure --hold when a PID-isolated command runner needs one foreground wrapper process",
    "to keep a newly-started daemon alive across separate wrapper invocations.",
    "Use feedback to produce a pasteable Beam report card with cheap version, stats, open-files,",
    "daemon registry, and daemon incident context.",
    "Feedback input must be a JSON object with required string fields: title, summary,",
    "reproduction, expected, and actual.",
    "For lean-sync / lean-refresh / lean-save / lean-close-save, diagnostics always stream for the",
    "current request;",
    "default is errors only, and +full widens the stream to warnings, info, and hints.",
    "Wrapper diagnostics and progress are human-facing on stderr.",
    "Set BEAM_DEBUG_TEXT=1 to print the exact escaped text and UTF-8 bytes sent for text-carrying",
    "Lean probe requests.",
    "For machine-readable streaming diagnostics/progress, use beam-client request-stream.",
    "For the Lean workflow contract and anti-patterns, see skills/lean-beam/SKILL.md."
  ]

end Beam.Cli
