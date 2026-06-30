#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import sys

registry_path = Path("supported-lean-toolchains")
workflow_path = Path(".github/workflows/ci.yml")


def load_supported_toolchains(path: Path) -> tuple[list[str], list[tuple[int, str]]]:
    toolchains: list[str] = []
    seen: set[str] = set()
    duplicates: list[tuple[int, str]] = []

    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line in seen:
            duplicates.append((line_no, line))
        seen.add(line)
        toolchains.append(line)

    return toolchains, duplicates


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def unquote_yaml_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def find_job_bounds(lines: list[str], job_name: str) -> tuple[int, int]:
    job_header = f"  {job_name}:"
    for start, line in enumerate(lines):
        if line == job_header:
            break
    else:
        raise RuntimeError(f"missing workflow job: {job_name}")

    job_indent = indent_of(lines[start])
    for end in range(start + 1, len(lines)):
        line = lines[end]
        if line.strip() and indent_of(line) <= job_indent and line.rstrip().endswith(":"):
            return start, end
    return start, len(lines)


def load_ci_matrix_toolchains(path: Path) -> tuple[list[str], list[tuple[int, str]]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    start, end = find_job_bounds(lines, "beam-toolchain-compat")

    for toolchain_line in range(start + 1, end):
        if lines[toolchain_line].strip() == "toolchain:":
            break
    else:
        raise RuntimeError("missing `toolchain:` matrix under beam-toolchain-compat")

    toolchain_indent = indent_of(lines[toolchain_line])
    toolchains: list[str] = []
    seen: set[str] = set()
    duplicates: list[tuple[int, str]] = []

    for idx in range(toolchain_line + 1, end):
        raw = lines[idx]
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if indent_of(raw) <= toolchain_indent:
            break
        if not line.startswith("- "):
            continue

        toolchain = unquote_yaml_scalar(line[2:])
        if toolchain in seen:
            duplicates.append((idx + 1, toolchain))
        seen.add(toolchain)
        toolchains.append(toolchain)

    if not toolchains:
        raise RuntimeError("empty `toolchain:` matrix under beam-toolchain-compat")

    return toolchains, duplicates


try:
    supported, supported_duplicates = load_supported_toolchains(registry_path)
    matrix, matrix_duplicates = load_ci_matrix_toolchains(workflow_path)
except RuntimeError as ex:
    print(f"toolchain CI matrix guard failed: {ex}", file=sys.stderr)
    sys.exit(1)

failures: list[str] = []

if not supported:
    failures.append(f"{registry_path}: no supported Lean toolchains listed")

for line_no, toolchain in supported_duplicates:
    failures.append(f"{registry_path}:{line_no}: duplicate supported toolchain: {toolchain}")

for line_no, toolchain in matrix_duplicates:
    failures.append(f"{workflow_path}:{line_no}: duplicate CI matrix toolchain: {toolchain}")

supported_set = set(supported)
matrix_set = set(matrix)

missing = [toolchain for toolchain in supported if toolchain not in matrix_set]
extra = [toolchain for toolchain in matrix if toolchain not in supported_set]

if missing:
    failures.append(
        "supported Lean toolchains missing from beam-toolchain-compat matrix:\n  "
        + "\n  ".join(missing)
    )

if extra:
    failures.append(
        "beam-toolchain-compat matrix contains toolchains not in supported-lean-toolchains:\n  "
        + "\n  ".join(extra)
    )

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(1)
PY
