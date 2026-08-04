#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
import sys

validated_registry_path = Path("validated-lean-toolchains")
compatible_registry_path = Path("compatible-lean-release-lines")
workflow_path = Path(".github/workflows/ci.yml")

canonical_toolchain_re = re.compile(
    r"^leanprover/lean4:v"
    r"(?P<major>0|[1-9][0-9]*)\."
    r"(?P<minor>0|[1-9][0-9]*)\."
    r"(?P<patch>0|[1-9][0-9]*)"
    r"(?:-rc(?P<rc>[1-9][0-9]*))?$"
)
release_line_re = re.compile(
    r"^leanprover/lean4:v"
    r"(?P<major>0|[1-9][0-9]*)\."
    r"(?P<minor>0|[1-9][0-9]*)$"
)


def load_registry_entries(path: Path) -> tuple[list[tuple[int, str]], list[tuple[int, str]]]:
    entries: list[tuple[int, str]] = []
    seen: set[str] = set()
    duplicates: list[tuple[int, str]] = []

    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        if entry in seen:
            duplicates.append((line_no, entry))
        seen.add(entry)
        entries.append((line_no, entry))

    return entries, duplicates


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


def load_release_line_ci_toolchain(path: Path) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    start, end = find_job_bounds(lines, "beam-release-line-compat")
    prefix = "run: bash tests/test-beam-toolchain-compat.sh "
    toolchains = [
        unquote_yaml_scalar(line.strip()[len(prefix):])
        for line in lines[start:end]
        if line.strip().startswith(prefix)
    ]
    if len(toolchains) != 1:
        raise RuntimeError(
            "beam-release-line-compat must run test-beam-toolchain-compat.sh for exactly one toolchain"
        )
    return toolchains[0]


try:
    validated_entries, validated_duplicates = load_registry_entries(validated_registry_path)
    compatible_entries, compatible_duplicates = load_registry_entries(compatible_registry_path)
    matrix, matrix_duplicates = load_ci_matrix_toolchains(workflow_path)
    release_line_ci_toolchain = load_release_line_ci_toolchain(workflow_path)
except RuntimeError as ex:
    print(f"toolchain CI matrix guard failed: {ex}", file=sys.stderr)
    sys.exit(1)

validated = [entry for _, entry in validated_entries]
compatible = [entry for _, entry in compatible_entries]
failures: list[str] = []

if not validated:
    failures.append(f"{validated_registry_path}: no validated Lean toolchains listed")
if not compatible:
    failures.append(f"{compatible_registry_path}: no compatible Lean release lines listed")

for line_no, toolchain in validated_entries:
    if canonical_toolchain_re.fullmatch(toolchain) is None:
        failures.append(
            f"{validated_registry_path}:{line_no}: invalid validated Lean toolchain: {toolchain}"
        )
for line_no, toolchain in validated_duplicates:
    failures.append(
        f"{validated_registry_path}:{line_no}: duplicate validated Lean toolchain: {toolchain}"
    )

for line_no, release_line in compatible_entries:
    if release_line_re.fullmatch(release_line) is None:
        failures.append(
            f"{compatible_registry_path}:{line_no}: invalid compatible Lean release line: {release_line}"
        )
for line_no, release_line in compatible_duplicates:
    failures.append(
        f"{compatible_registry_path}:{line_no}: duplicate compatible Lean release line: {release_line}"
    )

for line_no, toolchain in matrix_duplicates:
    failures.append(f"{workflow_path}:{line_no}: duplicate CI matrix toolchain: {toolchain}")

validated_set = set(validated)
matrix_set = set(matrix)
missing = [toolchain for toolchain in validated if toolchain not in matrix_set]
extra = [toolchain for toolchain in matrix if toolchain not in validated_set]

if missing:
    failures.append(
        "validated Lean toolchains missing from beam-toolchain-compat matrix:\n  "
        + "\n  ".join(missing)
    )
if extra:
    failures.append(
        "beam-toolchain-compat matrix contains toolchains not in validated-lean-toolchains:\n  "
        + "\n  ".join(extra)
    )

release_line_match = canonical_toolchain_re.fullmatch(release_line_ci_toolchain)
if release_line_match is None or release_line_match.group("rc") is None:
    failures.append(
        "beam-release-line-compat must use one canonical Lean release-candidate toolchain: "
        + release_line_ci_toolchain
    )
else:
    release_line = (
        "leanprover/lean4:v"
        + release_line_match.group("major")
        + "."
        + release_line_match.group("minor")
    )
    if release_line not in set(compatible):
        failures.append(
            "beam-release-line-compat toolchain is outside compatible-lean-release-lines: "
            + release_line_ci_toolchain
        )
if release_line_ci_toolchain in validated_set:
    failures.append(
        "beam-release-line-compat toolchain must not be exact-validated: "
        + release_line_ci_toolchain
    )

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(1)
PY
