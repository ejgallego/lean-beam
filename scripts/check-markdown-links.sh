#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

repo = Path.cwd()
md_files = subprocess.check_output(
    ["git", "ls-files", "*.md"],
    cwd=repo,
    text=True,
).splitlines()

link_re = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
scheme_re = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
failures: list[str] = []

for rel in md_files:
    path = repo / rel
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8")
    for match in link_re.finditer(text):
        raw_target = match.group(1).strip()
        if not raw_target:
            continue
        if raw_target.startswith("<") and raw_target.endswith(">"):
            raw_target = raw_target[1:-1]
        if raw_target.startswith("#"):
            continue
        if raw_target.startswith("//") or scheme_re.match(raw_target):
            continue

        target = unquote(raw_target.split("#", 1)[0].split("?", 1)[0])
        if not target:
            continue

        if target.startswith("/"):
            dest = repo / target.lstrip("/")
        else:
            dest = path.parent / target
        dest = dest.resolve(strict=False)

        try:
            dest.relative_to(repo)
        except ValueError:
            failures.append(f"{rel}: link leaves repository: {raw_target}")
            continue

        if not dest.exists():
            failures.append(f"{rel}: missing link target: {raw_target}")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(1)
PY
