#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

lake build \
  RunAt:shared \
  beam-cli \
  beam-daemon \
  beam-client \
  lean-beam-mcp \
  RunAtTest.Broker.StreamDedupTest \
  beam-broker-protocol-test \
  beam-broker-pending-test \
  beam-daemon-smoke-test \
  beam-daemon-save-stream-test \
  beam-daemon-request-stream-test \
  beam-daemon-startup-handshake-test \
  beam-cli-daemon-test \
  beam-mcp-projection-test \
  beam-mcp-protocol-test \
  > /dev/null

.lake/build/bin/beam-broker-protocol-test > /dev/null
.lake/build/bin/beam-broker-pending-test > /dev/null
.lake/build/bin/beam-cli-daemon-test > /dev/null
.lake/build/bin/beam-mcp-projection-test > /dev/null
.lake/build/bin/beam-mcp-protocol-test > /dev/null
.lake/build/bin/beam-daemon-smoke-test > /dev/null
.lake/build/bin/beam-daemon-save-stream-test > /dev/null
.lake/build/bin/beam-daemon-request-stream-test > /dev/null
.lake/build/bin/beam-daemon-startup-handshake-test > /dev/null

python3 tests/test-mcp-stdio.py --iterations 1 --restart-cycles 1 > /dev/null
python3 tests/test-mcp-http-bridge.py > /dev/null
scripts/lean-beam-mcp --root tests/save_olean_project --self-check PositionEmptyLine.lean > /dev/null

self_check_missing_file_err="$(mktemp /tmp/lean-beam-mcp-self-check-missing-file-XXXXXX)"
if scripts/lean-beam-mcp --root tests/save_olean_project --self-check DoesNotExist.lean \
    > /dev/null 2>"$self_check_missing_file_err"; then
  echo "expected MCP self-check to reject a missing Lean file" >&2
  rm -f "$self_check_missing_file_err"
  exit 1
fi
if ! grep -Eiq 'No such file|failed to canonicalize|does not exist' "$self_check_missing_file_err"; then
  echo "expected missing-file MCP self-check failure to explain the path error" >&2
  cat "$self_check_missing_file_err" >&2
  rm -f "$self_check_missing_file_err"
  exit 1
fi
rm -f "$self_check_missing_file_err"

self_check_missing_root="/tmp/lean-beam-mcp-missing-root-$$"
self_check_missing_root_err="$(mktemp /tmp/lean-beam-mcp-self-check-missing-root-XXXXXX)"
rm -rf -- "$self_check_missing_root"
if scripts/lean-beam-mcp --root "$self_check_missing_root" --self-check PositionEmptyLine.lean \
    > /dev/null 2>"$self_check_missing_root_err"; then
  echo "expected MCP self-check to reject a missing root" >&2
  rm -f "$self_check_missing_root_err"
  exit 1
fi
if ! grep -Eiq 'No such file|failed to canonicalize|does not exist' "$self_check_missing_root_err"; then
  echo "expected missing-root MCP self-check failure to explain the root error" >&2
  cat "$self_check_missing_root_err" >&2
  rm -f "$self_check_missing_root_err"
  exit 1
fi
rm -f "$self_check_missing_root_err"

mcp_smoke_out="$(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"$/lean/runAt","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"shutdown"}' |
    .lake/build/bin/lean-beam-mcp --root tests/save_olean_project
)"

MCP_SMOKE_OUT="${mcp_smoke_out}" python3 - <<'PY'
import json
import os
import sys

lines = [json.loads(line) for line in os.environ["MCP_SMOKE_OUT"].splitlines() if line.strip()]
if len(lines) != 4:
    print(f"expected 4 MCP responses, got {len(lines)}", file=sys.stderr)
    print(os.environ["MCP_SMOKE_OUT"], file=sys.stderr)
    sys.exit(1)

init, tools, raw_tool, shutdown = lines
if init.get("result", {}).get("protocolVersion") != "2025-11-25":
    print("MCP initialize did not negotiate the expected protocol version", file=sys.stderr)
    sys.exit(1)

tool_names = {tool.get("name") for tool in tools.get("result", {}).get("tools", [])}
if "lean_run_at" not in tool_names or "$/lean/runAt" in tool_names or "lean_request_at" in tool_names:
    print(f"unexpected MCP tool list: {sorted(tool_names)}", file=sys.stderr)
    sys.exit(1)

if raw_tool.get("error", {}).get("code") != -32602:
    print(f"expected raw LSP tool call to be rejected as invalid params: {raw_tool}", file=sys.stderr)
    sys.exit(1)

if shutdown.get("result") != {}:
    print(f"expected clean MCP shutdown response: {shutdown}", file=sys.stderr)
    sys.exit(1)
PY
