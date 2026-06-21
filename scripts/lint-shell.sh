#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

files=(
  scripts/*.sh
  scripts/lean-beam
  scripts/lean-beam-search
  tests/*.sh
  tests/lib/*.sh
)

shellcheck -x ${files[@]+"${files[@]}"}

python3 - <<'PY'
from pathlib import Path
import re
import sys

paths = [
    *Path("scripts").glob("*.sh"),
    Path("scripts/lean-beam"),
    Path("scripts/lean-beam-search"),
    *Path("tests").glob("*.sh"),
    *Path("tests/lib").glob("*.sh"),
]
safe_re = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\+"\$\{\1\[@\]\}"\}')
raw_re = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}')
failures: list[str] = []

for path in sorted(set(paths)):
    if not path.exists():
        continue
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        safe_spans = [match.span() for match in safe_re.finditer(line)]
        for match in raw_re.finditer(line):
            if not any(start <= match.start() and match.end() <= end for start, end in safe_spans):
                failures.append(f"{path}:{line_no}: {match.group(0)}")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    raw_example = "${" + "array[@]}"
    safe_example = "${" + "array[@]+\"" + "${" + "array[@]}\"}"
    print(
        f"\nShell scripts must not use raw \"{raw_example}\" expansions.\n"
        "macOS ships Bash 3.2, where empty arrays can still trip `set -u`.\n"
        "Use the Bash-3.2-safe form:\n"
        f"  {safe_example}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
