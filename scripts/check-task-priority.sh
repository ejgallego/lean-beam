#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import pathlib
import re
import sys

roots = [pathlib.Path(arg) for arg in sys.argv[1:]] or [
    pathlib.Path("Beam"),
    pathlib.Path("BeamTest"),
]

direct_as_task = re.compile(r"\b(?:IO|BaseIO|EIO)\.asTask\b")
dedicated_priority = re.compile(r"(?:Task\.Priority\.dedicated|prio\s*:=\s*\.dedicated)")

violations = []

for root in roots:
    files = sorted(root.rglob("*.lean")) if root.is_dir() else [root]
    for path in files:
        text = path.read_text()
        for lineno, line in enumerate(text.splitlines(), start=1):
            match = direct_as_task.search(line)
            if not match:
                continue
            # ServerTask.BaseIO.asTask and friends are already dedicated wrappers.
            if match.start() > 0 and line[match.start() - 1] == ".":
                continue
            if not dedicated_priority.search(line):
                violations.append(f"{path}:{lineno}:{line.strip()}")

if violations:
    print(
        "direct IO/BaseIO/EIO.asTask calls must choose dedicated priority explicitly; "
        "blocking or long-lived tasks must not consume Lean's bounded worker pool.",
        file=sys.stderr,
    )
    print("\n".join(violations), file=sys.stderr)
    sys.exit(1)
PY
