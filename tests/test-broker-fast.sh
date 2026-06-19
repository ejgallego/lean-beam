#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/check-daemon-safety.sh
bash scripts/check-task-priority.sh
bash scripts/check-markdown-links.sh

lake build \
  RunAt:shared \
  beam-cli \
  beam-daemon \
  beam-client \
  lean-beam-mcp \
  RunAtTest.Broker.StreamDedupTest \
  beam-broker-protocol-test \
  beam-broker-pending-test \
  beam-broker-document-state-test \
  beam-broker-open-docs-test \
  beam-daemon-smoke-test \
  beam-daemon-save-stream-test \
  beam-daemon-request-stream-test \
  beam-sync-summary-test \
  beam-sync-summary-delta-test \
  beam-daemon-startup-handshake-test \
  beam-cli-daemon-test \
  beam-mcp-projection-test \
  beam-mcp-protocol-test \
  > /dev/null

.lake/build/bin/beam-broker-protocol-test > /dev/null
.lake/build/bin/beam-broker-pending-test > /dev/null
.lake/build/bin/beam-broker-document-state-test > /dev/null
.lake/build/bin/beam-broker-open-docs-test > /dev/null
.lake/build/bin/beam-cli-daemon-test > /dev/null
.lake/build/bin/beam-mcp-projection-test > /dev/null
.lake/build/bin/beam-mcp-protocol-test > /dev/null
.lake/build/bin/beam-daemon-smoke-test > /dev/null
.lake/build/bin/beam-daemon-save-stream-test > /dev/null
.lake/build/bin/beam-daemon-request-stream-test > /dev/null
.lake/build/bin/beam-sync-summary-test > /dev/null
.lake/build/bin/beam-sync-summary-delta-test > /dev/null
.lake/build/bin/beam-daemon-startup-handshake-test > /dev/null

python3 tests/test-mcp-stdio.py --iterations 1 --restart-cycles 1 > /dev/null
python3 tests/test-mcp-http-bridge.py > /dev/null
LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS=60000 \
  scripts/lean-beam-mcp --root tests/save_olean_project --self-check PositionEmptyLine.lean > /dev/null

self_check_timeout_dir="$(mktemp -d /tmp/lean-beam-mcp-self-check-timeout-XXXXXX)"
self_check_timeout_err="$(mktemp /tmp/lean-beam-mcp-self-check-timeout-err-XXXXXX)"
self_check_fake_cli="$self_check_timeout_dir/beam-cli"
self_check_fake_cli_pid="$self_check_timeout_dir/beam-cli.pid"
# shellcheck disable=SC2016 # Keep fake-script variables unexpanded until the fake CLI runs.
printf '%s\n' \
  '#!/usr/bin/env sh' \
  'printf "%s\n" "$$" > "$LEAN_BEAM_FAKE_CLI_PID"' \
  'sleep 30' \
  > "$self_check_fake_cli"
chmod +x "$self_check_fake_cli"
if LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS=10000 \
    LEAN_BEAM_FAKE_CLI_PID="$self_check_fake_cli_pid" \
    .lake/build/bin/lean-beam-mcp --root tests/save_olean_project \
      --beam-cli "$self_check_fake_cli" --self-check PositionEmptyLine.lean \
    > /dev/null 2>"$self_check_timeout_err"; then
  echo "expected MCP self-check to time out while setting up the workspace" >&2
  if [ -s "$self_check_fake_cli_pid" ]; then
    kill "$(cat "$self_check_fake_cli_pid")" 2> /dev/null || true
  fi
  rm -rf -- "$self_check_timeout_dir"
  rm -f "$self_check_timeout_err"
  exit 1
fi
if ! grep -Fq \
    'timed out after 10000 ms waiting for lean-beam-mcp self-check lean_init_workspace response' \
    "$self_check_timeout_err"; then
  echo "expected MCP self-check timeout to identify the workspace setup phase" >&2
  cat "$self_check_timeout_err" >&2
  if [ -s "$self_check_fake_cli_pid" ]; then
    kill "$(cat "$self_check_fake_cli_pid")" 2> /dev/null || true
  fi
  rm -rf -- "$self_check_timeout_dir"
  rm -f "$self_check_timeout_err"
  exit 1
fi
if [ -s "$self_check_fake_cli_pid" ]; then
  kill "$(cat "$self_check_fake_cli_pid")" 2> /dev/null || true
fi
rm -rf -- "$self_check_timeout_dir"
rm -f "$self_check_timeout_err"

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

cli_non_workspace_root="$(mktemp -d /tmp/beam-cli-non-workspace-root-XXXXXX)"
cli_non_workspace_err="$(mktemp /tmp/beam-cli-non-workspace-root-err-XXXXXX)"
if .lake/build/bin/beam-cli --root "$cli_non_workspace_root" doctor lean \
    > /dev/null 2>"$cli_non_workspace_err"; then
  echo "expected beam-cli Lean root validation to reject a non-workspace root" >&2
  rm -rf -- "$cli_non_workspace_root"
  rm -f "$cli_non_workspace_err"
  exit 1
fi
if ! grep -Fq 'workspace root is not a Lean/Lake project' "$cli_non_workspace_err"; then
  echo "expected non-workspace CLI root failure to use the shared workspace error" >&2
  cat "$cli_non_workspace_err" >&2
  rm -rf -- "$cli_non_workspace_root"
  rm -f "$cli_non_workspace_err"
  exit 1
fi
rm -rf -- "$cli_non_workspace_root"
rm -f "$cli_non_workspace_err"

wrapper_todo_control_dir="$(mktemp -d /tmp/lean-beam-wrapper-todo-XXXXXX)"
wrapper_todo_out="$(mktemp /tmp/lean-beam-wrapper-todo-out-XXXXXX)"
wrapper_todo_err="$(mktemp /tmp/lean-beam-wrapper-todo-err-XXXXXX)"
wrapper_todo_cleanup() {
  BEAM_CONTROL_DIR="$wrapper_todo_control_dir" \
    scripts/lean-beam --root tests/save_olean_project shutdown > /dev/null 2>&1 || true
  rm -rf -- "$wrapper_todo_control_dir"
  rm -f "$wrapper_todo_out" "$wrapper_todo_err"
}

if ! BEAM_CONTROL_DIR="$wrapper_todo_control_dir" \
    scripts/lean-beam --root tests/save_olean_project \
      todo TodoSmoke.lean 13 0 14 0 --kind sorry --suggest none \
    > "$wrapper_todo_out" 2>"$wrapper_todo_err"; then
  echo "expected lean-beam todo wrapper smoke to succeed" >&2
  cat "$wrapper_todo_err" >&2
  wrapper_todo_cleanup
  exit 1
fi

if ! WRAPPER_TODO_OUT="$wrapper_todo_out" python3 - <<'PY'
import json
import os
import sys

with open(os.environ["WRAPPER_TODO_OUT"], encoding="utf-8") as f:
    response = json.load(f)

if response.get("ok") is not True:
    print(f"expected lean-beam todo wrapper response ok=true, got {response}", file=sys.stderr)
    sys.exit(1)

items = response.get("result", {}).get("items", [])
if len(items) != 1:
    print(f"expected one wrapper todo item, got {items}", file=sys.stderr)
    sys.exit(1)

item = items[0]
if item.get("kind") != "sorry":
    print(f"expected wrapper todo kind sorry, got {item}", file=sys.stderr)
    sys.exit(1)

if item.get("runAtPosition") != {"line": 13, "character": 2}:
    print(f"unexpected wrapper todo runAtPosition: {item}", file=sys.stderr)
    sys.exit(1)

if "runAtText" in item:
    print(f"expected --suggest none to omit wrapper runAtText: {item}", file=sys.stderr)
    sys.exit(1)
PY
then
  wrapper_todo_cleanup
  exit 1
fi
wrapper_todo_cleanup

mcp_smoke_out="$(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lean_todo","arguments":{"path":"TodoSmoke.lean","start_line":13,"start_character":0,"end_line":14,"end_character":0,"kinds":["sorry"],"suggest":"none"}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"$/lean/runAt","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"shutdown"}' |
    scripts/lean-beam-mcp --root tests/save_olean_project
)"

MCP_SMOKE_OUT="${mcp_smoke_out}" python3 - <<'PY'
import json
import os
import sys

lines = [json.loads(line) for line in os.environ["MCP_SMOKE_OUT"].splitlines() if line.strip()]
if len(lines) != 5:
    print(f"expected 5 MCP responses, got {len(lines)}", file=sys.stderr)
    print(os.environ["MCP_SMOKE_OUT"], file=sys.stderr)
    sys.exit(1)

init, tools, todo, raw_tool, shutdown = lines
if init.get("result", {}).get("protocolVersion") != "2025-11-25":
    print("MCP initialize did not negotiate the expected protocol version", file=sys.stderr)
    sys.exit(1)

tool_names = {tool.get("name") for tool in tools.get("result", {}).get("tools", [])}
if "lean_run_at" not in tool_names or "lean_todo" not in tool_names or "$/lean/runAt" in tool_names or "lean_request_at" in tool_names:
    print(f"unexpected MCP tool list: {sorted(tool_names)}", file=sys.stderr)
    sys.exit(1)

todo_content = todo.get("result", {}).get("structuredContent", {})
todo_items = todo_content.get("items", [])
if len(todo_items) != 1 or todo_items[0].get("kind") != "sorry":
    print(f"expected lean_todo MCP smoke to return one sorry item: {todo}", file=sys.stderr)
    sys.exit(1)

if todo_items[0].get("run_at_position") != {"line": 13, "character": 2}:
    print(f"unexpected MCP todo run_at_position: {todo}", file=sys.stderr)
    sys.exit(1)

if "run_at_text" in todo_items[0]:
    print(f"expected MCP todo suggest=none to omit run_at_text: {todo}", file=sys.stderr)
    sys.exit(1)

if raw_tool.get("error", {}).get("code") != -32602:
    print(f"expected raw LSP tool call to be rejected as invalid params: {raw_tool}", file=sys.stderr)
    sys.exit(1)

if shutdown.get("result") != {}:
    print(f"expected clean MCP shutdown response: {shutdown}", file=sys.stderr)
    sys.exit(1)
PY
