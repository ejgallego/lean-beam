#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

report_matches() {
  local label="$1"
  local pattern="$2"
  shift 2
  local out
  if command -v rg > /dev/null 2>&1; then
    out="$(rg -n "$pattern" "$@" || true)"
  else
    out="$(python3 - "$pattern" "$@" <<'PY'
import pathlib
import re
import sys

pattern = re.compile(sys.argv[1])
paths = [pathlib.Path(arg) for arg in sys.argv[2:]]
matches = []

for path in paths:
    files = path.rglob("*.lean") if path.is_dir() else [path]
    for file in files:
        try:
            text = file.read_text()
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if pattern.search(line):
                matches.append(f"{file}:{lineno}:{line}")

if matches:
    print("\n".join(matches))
PY
)"
  fi
  if [ -n "$out" ]; then
    printf '%s\n%s\n' "$label" "$out" >&2
    fail=1
  fi
}

report_matches \
  "daemon/importable broker code must not call process-wide exit APIs:" \
  '\b(IO\.Process\.exit|IO\.exit|Process\.exit|exitIfErrorCode)\b' \
  Beam/Broker

report_matches \
  "daemon/importable broker code must not use Lake noBuild configs directly:" \
  'noBuild\s*:=\s*true|runBuild.*noBuild' \
  Beam/Broker

report_matches \
  "daemon/importable broker code must not enable Lake toolchain updates:" \
  'updateToolchain\s*:=\s*true' \
  Beam/Broker

python3 - <<'PY'
import pathlib
import re
import sys

failed = False
for path in pathlib.Path("Beam/Broker").rglob("*.lean"):
    text = path.read_text()
    for match in re.finditer(r"LoadConfig\s*:=\s*\{", text):
        start = match.end()
        depth = 1
        idx = start
        while idx < len(text) and depth:
            char = text[idx]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            idx += 1
        if depth:
            print(f"{path}: unterminated LoadConfig literal", file=sys.stderr)
            failed = True
            continue
        block = text[start : idx - 1]
        if "updateToolchain := false" not in block:
            line = text.count("\n", 0, match.start()) + 1
            print(
                f"{path}:{line}: broker LoadConfig must set updateToolchain := false",
                file=sys.stderr,
            )
            failed = True

if failed:
    sys.exit(1)
PY

if [ "$fail" -ne 0 ]; then
  exit 1
fi
