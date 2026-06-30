#!/usr/bin/env python3
"""Validate the LSP test coverage registry.

This checker is intentionally metadata-only. It keeps the LSP method list, required
coverage tags, and concrete test pointers synchronized while the executable tests
remain in the existing Lean, scenario, and interactive harnesses.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from collections import defaultdict


ROOT = pathlib.Path(__file__).resolve().parents[2]
METHODS_PATH = ROOT / "tests" / "lsp-coverage" / "methods.json"
CASES_PATH = ROOT / "tests" / "lsp-coverage" / "cases.json"
PLUGIN_PATH = ROOT / "Beam" / "LSP" / "Plugin.lean"
REGISTER_HANDLER_RE = re.compile(
    r"\bregisterLspRequestHandler\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)"
)


def fail(message: str) -> None:
    print(f"lsp-coverage: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: pathlib.Path) -> object:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as err:
        fail(f"{path}: invalid JSON: {err}")


def split_pointer(pointer: str) -> tuple[pathlib.Path, str | None]:
    path_text, sep, anchor = pointer.partition("#")
    if not path_text:
        fail(f"empty pointer path in {pointer!r}")
    return ROOT / path_text, anchor if sep else None


def require_pointer(pointer: str) -> None:
    path, anchor = split_pointer(pointer)
    if not path.exists():
        fail(f"pointer path does not exist: {pointer}")
    if anchor is None:
        return
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".lean":
        pattern = re.compile(rf"\bdef\s+{re.escape(anchor)}\b")
        if pattern.search(text) is None and anchor not in text:
            fail(f"pointer anchor not found: {pointer}")
    elif anchor not in text:
        fail(f"pointer anchor not found: {pointer}")


def require_method_definition(entry: dict[str, object]) -> None:
    definition = entry.get("definition")
    method = entry.get("method")
    if not isinstance(definition, str) or not isinstance(method, str):
        fail(f"method entry needs string method and definition: {entry}")
    path, anchor = split_pointer(definition)
    if anchor is None:
        fail(f"method definition needs an anchor: {definition}")
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(rf"\bdef\s+{re.escape(anchor)}\s*:\s*String\s*:=\s*\"{re.escape(method)}\"")
    if pattern.search(text) is None:
        fail(f"method definition does not define {method!r}: {definition}")


def require_unique_strings(label: str, value: object) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        fail(f"{label} must be an array of strings")
    seen: set[str] = set()
    duplicates: list[str] = []
    for item in value:
        if item in seen and item not in duplicates:
            duplicates.append(item)
        seen.add(item)
    if duplicates:
        fail(f"{label} has duplicate entries: {', '.join(duplicates)}")
    return value


def registered_lsp_method_symbols(plugin_text: str) -> list[str]:
    symbols = REGISTER_HANDLER_RE.findall(plugin_text)
    if not symbols:
        fail(f"{PLUGIN_PATH}: no registerLspRequestHandler calls found")
    seen: set[str] = set()
    duplicates: list[str] = []
    for symbol in symbols:
        if symbol in seen and symbol not in duplicates:
            duplicates.append(symbol)
        seen.add(symbol)
    if duplicates:
        fail(f"{PLUGIN_PATH}: duplicate registered LSP handler symbols: {', '.join(duplicates)}")
    return symbols


def main() -> int:
    methods_doc = load_json(METHODS_PATH)
    cases_doc = load_json(CASES_PATH)
    if not isinstance(methods_doc, dict) or not isinstance(methods_doc.get("methods"), list):
        fail(f"{METHODS_PATH}: expected object with methods array")
    if not isinstance(cases_doc, dict) or not isinstance(cases_doc.get("cases"), list):
        fail(f"{CASES_PATH}: expected object with cases array")

    plugin_text = PLUGIN_PATH.read_text(encoding="utf-8")
    registered_symbols = registered_lsp_method_symbols(plugin_text)
    registered_symbol_set = set(registered_symbols)
    methods: dict[str, dict[str, object]] = {}
    method_symbols: dict[str, str] = {}
    for raw in methods_doc["methods"]:
        if not isinstance(raw, dict):
            fail(f"method entry must be an object: {raw}")
        method = raw.get("method")
        family = raw.get("family")
        symbol = raw.get("registrySymbol")
        if not isinstance(method, str) or not isinstance(family, str) or not family or not isinstance(symbol, str):
            fail(f"method entry needs method, family, and registrySymbol: {raw}")
        required = require_unique_strings(f"{method}: requiredCoverage", raw.get("requiredCoverage"))
        if method in methods:
            fail(f"duplicate method entry: {method}")
        if symbol in method_symbols:
            fail(f"duplicate registrySymbol {symbol}: {method_symbols[symbol]} and {method}")
        if symbol not in registered_symbol_set:
            fail(f"registered method symbol is not registered by Beam/LSP/Plugin.lean: {symbol}")
        require_method_definition(raw)
        methods[method] = raw
        method_symbols[symbol] = method

    missing_registry_entries = [
        symbol for symbol in registered_symbols
        if symbol not in method_symbols
    ]
    if missing_registry_entries:
        fail(
            "registered LSP methods missing from tests/lsp-coverage/methods.json: "
            + ", ".join(missing_registry_entries)
        )

    seen_case_ids: set[str] = set()
    covered: dict[str, set[str]] = defaultdict(set)
    for raw in cases_doc["cases"]:
        if not isinstance(raw, dict):
            fail(f"case entry must be an object: {raw}")
        case_id = raw.get("id")
        method = raw.get("method")
        coverage = raw.get("coverage")
        pointer = raw.get("pointer")
        if not isinstance(case_id, str) or not isinstance(method, str):
            fail(f"case entry needs string id and method: {raw}")
        if case_id in seen_case_ids:
            fail(f"duplicate case id: {case_id}")
        seen_case_ids.add(case_id)
        if method not in methods:
            fail(f"{case_id}: unknown method {method!r}")
        coverage_tags = require_unique_strings(f"{case_id}: coverage", coverage)
        if not coverage_tags:
            fail(f"{case_id}: coverage must not be empty")
        method_tags = set(methods[method]["requiredCoverage"])
        unknown_tags = sorted(set(coverage_tags) - method_tags)
        if unknown_tags:
            fail(f"{case_id}: coverage tag not declared for {method}: {', '.join(unknown_tags)}")
        if not isinstance(pointer, str):
            fail(f"{case_id}: pointer must be a string")
        require_pointer(pointer)
        covered[method].update(coverage_tags)

    missing_messages: list[str] = []
    for method, entry in methods.items():
        required = set(entry["requiredCoverage"])
        missing = sorted(required - covered[method])
        if missing:
            missing_messages.append(f"{method}: missing {', '.join(missing)}")
    if missing_messages:
        fail("required coverage missing:\n  " + "\n  ".join(missing_messages))

    print(f"lsp-coverage: {len(methods)} methods, {len(seen_case_ids)} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
