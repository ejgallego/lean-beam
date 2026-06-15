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
    "  beam [--root PATH] [--socket PATH | --port N] ensure [lean|rocq] [--hold]",
    "  beam [--root PATH] cancel <request-id>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-at <path> <line> <character> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-at-handle <path> <line> <character> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-hover <path> <line> <character>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-goals-after <path> <line> <character>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-goals-prev <path> <line> <character>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-with <path> <handle-json|-|--handle-file <path>> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-run-with-linear <path> <handle-json|-|--handle-file <path>> [--stdin | --text-file <path> | -- <text...> | <text...>]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-release <path> <handle-json|-|--handle-file <path>>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-sync <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-refresh <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-save <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] lean-close <path>",
    "  beam [--root PATH] [--socket PATH | --port N] lean-close-save <path> [+full]",
    "  beam [--root PATH] [--socket PATH | --port N] rocq-goals-after <path> <line> <character> [text...]",
    "  beam [--root PATH] [--socket PATH | --port N] rocq-goals-prev <path> <line> <character> [text...]",
    "  beam bundle-install <toolchain>",
    "  beam supported-toolchains lean",
    "  beam [--root PATH] doctor lean|rocq",
    "  beam [--root PATH] open-files",
    "  beam [--root PATH] cancel <request-id>",
    "  beam [--root PATH] stats",
    "  beam [--root PATH] reset-stats",
    "  beam [--root PATH] shutdown",
    "  beam experimental",
    "",
    "Lean edit loop: save the file, then run lean-sync. lean-save is lean-sync plus a",
    "workspace-module checkpoint, lean-refresh is lean-close plus lean-sync, and lean-close-save",
    "adds closing the tracked file afterward.",
    "Separate lean-run-at calls are independent probes on the current saved file snapshot.",
    "For exact speculative chaining, use lean-run-at-handle and then lean-run-with /",
    "lean-run-with-linear.",
    "For multiline text-carrying Lean probes, prefer --stdin or --text-file <path>; use -- before",
    "text that itself starts with --.",
    "For handle-based commands, use --handle-file <path> when you do not want to inline handle json.",
    "Use ensure --hold when a PID-isolated command runner needs one foreground wrapper process",
    "to keep a newly-started daemon alive across separate wrapper invocations.",
    "For lean-sync / lean-refresh / lean-save / lean-close-save, diagnostics always stream for the",
    "current request;",
    "default is errors only, and +full widens the stream to warnings, info, and hints.",
    "Wrapper diagnostics and progress are human-facing on stderr.",
    "Set BEAM_DEBUG_TEXT=1 to print the exact escaped text and UTF-8 bytes sent for text-carrying",
    "Lean probe requests.",
    "For machine-readable streaming diagnostics/progress, use beam-client request-stream.",
    "",
    "Expert-only experimental commands are documented in docs/experimental.md.",
    "For the Lean workflow contract and anti-patterns, see skills/lean-beam/SKILL.md."
  ]

def printExperimentalInfo (home : System.FilePath) : IO Unit := do
  let doc := home / "docs" / "experimental.md"
  IO.println s!"Experimental expert commands live in {doc}"
  IO.println "This is an unstable broker escape hatch, not part of the stable runAt contract."
  IO.println "Current experimental entry point: lean-beam request-at"
  IO.println "Unsupported or broken compatibility aliases may still exist for tests; they are not part of the supported or experimental surface."

end Beam.Cli
