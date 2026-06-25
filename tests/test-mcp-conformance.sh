#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-mcp-conformance}"

if ! command -v npx >/dev/null 2>&1; then
  echo "error: npx is required to run MCP conformance tests" >&2
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/lean-beam-mcp-conformance-XXXXXX)"
npm_cache="${MCP_CONFORMANCE_NPM_CACHE:-$tmp_dir/npm-cache}"
conformance_package="${MCP_CONFORMANCE_PACKAGE:-@modelcontextprotocol/conformance@0.1.16}"
bridge_ready_timeout="${MCP_CONFORMANCE_BRIDGE_READY_TIMEOUT:-30}"
bridge_pid=""
bridge_url=""
bridge_scenario_dir=""
bridge_ready_file=""
bridge_env=()
if [ -n "${GITHUB_ACTIONS:-}" ] || [ "${BEAM_MCP_HTTP_BRIDGE_TRACE:-0}" != "0" ]; then
  bridge_env+=("BEAM_MCP_HTTP_BRIDGE_TRACE=${BEAM_MCP_HTTP_BRIDGE_TRACE:-1}")
  if [ "${BEAM_MCP_SERVER_TRACE:-1}" != "0" ]; then
    bridge_env+=("BEAM_MCP_SERVER_TRACE=1")
  fi
fi

cleanup() {
  if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" >/dev/null 2>&1; then
    kill "$bridge_pid" >/dev/null 2>&1 || true
    wait "$bridge_pid" >/dev/null 2>&1 || true
  fi
  case "$tmp_dir" in
    /tmp/lean-beam-mcp-conformance-*)
      rm -rf -- "$tmp_dir"
      ;;
    *)
      echo "refusing to clean unexpected temp dir: $tmp_dir" >&2
      ;;
  esac
}
trap cleanup EXIT

shared_lib_ext() {
  case "$(uname -s)" in
    Darwin)
      printf 'dylib\n'
      ;;
    CYGWIN*|MINGW*|MSYS*|Windows_NT)
      printf 'dll\n'
      ;;
    *)
      printf 'so\n'
      ;;
  esac
}

shared_lib_name() {
  case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*|Windows_NT)
      printf 'runAt_RunAt.%s\n' "$(shared_lib_ext)"
      ;;
    *)
      printf 'librunAt_RunAt.%s\n' "$(shared_lib_ext)"
      ;;
  esac
}

wait_for_ready_url() {
  local ready_file="$1"
  local timeout="$2"
  python3 - "$ready_file" "$timeout" <<'PY'
import json
import pathlib
import sys
import time

ready = pathlib.Path(sys.argv[1])
timeout = float(sys.argv[2])
deadline = time.monotonic() + timeout
while time.monotonic() < deadline:
    if ready.exists():
        print(json.loads(ready.read_text())["url"])
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(f"timed out after {timeout:g}s waiting for MCP bridge ready file {ready}")
PY
}

print_file_tail() {
  local label="$1"
  local file="$2"
  local lines="${BEAM_CI_LOG_TAIL_LINES:-160}"
  printf '%s\n' "--- ${label}: ${file} ---" >&2
  if [ -s "$file" ]; then
    tail -n "$lines" "$file" >&2 || true
  elif [ -e "$file" ]; then
    printf '%s\n' "<empty>" >&2
  else
    printf '%s\n' "<missing>" >&2
  fi
}

print_runtime_context() {
  printf '%s\n' "--- runner context ---" >&2
  printf 'uname: %s\n' "$(uname -a 2>/dev/null || printf '<unavailable>')" >&2
  if command -v sysctl >/dev/null 2>&1; then
    printf 'sysctl hw.ncpu: %s\n' "$(sysctl -n hw.ncpu 2>/dev/null || printf '<unavailable>')" >&2
    printf 'sysctl hw.logicalcpu: %s\n' "$(sysctl -n hw.logicalcpu 2>/dev/null || printf '<unavailable>')" >&2
  fi
  if command -v nproc >/dev/null 2>&1; then
    printf 'nproc: %s\n' "$(nproc 2>/dev/null || printf '<unavailable>')" >&2
  fi
  printf 'GITHUB_ACTIONS=%s RUNNER_OS=%s RUNNER_ARCH=%s ImageOS=%s ImageVersion=%s\n' \
    "${GITHUB_ACTIONS:-}" "${RUNNER_OS:-}" "${RUNNER_ARCH:-}" "${ImageOS:-}" "${ImageVersion:-}" >&2
  printf 'LEAN_NUM_THREADS=%s LEAN_OPTIONS=%s\n' "${LEAN_NUM_THREADS:-}" "${LEAN_OPTIONS:-}" >&2
}

print_process_snapshot() {
  printf '%s\n' "--- process snapshot ---" >&2
  if command -v ps >/dev/null 2>&1; then
    ps -ef 2>/dev/null | awk '
      /mcp_http_bridge.py|lean-beam-mcp|beam-daemon|lean --server/ && !/awk / { print }
    ' >&2 || true
  else
    printf '%s\n' "<ps unavailable>" >&2
  fi
}

should_run_python_getfqdn_probe() {
  case "${BEAM_MCP_HTTP_PYTHON_GETFQDN_PROBE:-}" in
    0|false|False|FALSE|no|No|NO)
      return 1
      ;;
    1|true|True|TRUE|yes|Yes|YES)
      return 0
      ;;
  esac
  [ -n "${GITHUB_ACTIONS:-}" ] && [ "${RUNNER_OS:-$(uname -s)}" = "macOS" ]
}

run_python_getfqdn_probe() {
  local probe_timeout="${BEAM_MCP_HTTP_PYTHON_GETFQDN_PROBE_TIMEOUT:-5}"
  local sample_duration="${BEAM_MCP_HTTP_PYTHON_GETFQDN_SAMPLE_SECONDS:-2}"
  local probe_rc
  if ! should_run_python_getfqdn_probe; then
    return
  fi
  printf '%s\n' "--- python socket.getfqdn probe ---" >&2
  python3 tests/mcp_http_python_getfqdn_probe.py \
    --timeout "$probe_timeout" \
    --sample-duration "$sample_duration" >&2 || {
    probe_rc="$?"
    printf 'python socket.getfqdn probe exited with code %s\n' "$probe_rc" >&2
  }
}

run_resolver_probe() {
  local scenario_dir="$1"
  local probe_src="tests/mcp_http_resolver_probe.c"
  local probe_bin="$scenario_dir/mcp_http_resolver_probe"
  local probe_build_log="$scenario_dir/resolver-probe.build.log"
  local probe_timeout="${BEAM_MCP_HTTP_RESOLVER_PROBE_TIMEOUT:-5}"
  local probe_rc
  printf '%s\n' "--- localhost resolver probe ---" >&2
  if ! command -v cc >/dev/null 2>&1; then
    printf '%s\n' "cc unavailable; skipping resolver probe" >&2
    return
  fi
  if ! cc -Wall -Wextra -O2 "$probe_src" -o "$probe_bin" > "$probe_build_log" 2>&1; then
    printf '%s\n' "failed to build resolver probe" >&2
    print_file_tail "resolver probe build log" "$probe_build_log"
    return
  fi
  "$probe_bin" "$probe_timeout" >&2 || {
    probe_rc="$?"
    printf 'resolver probe exited with code %s\n' "$probe_rc" >&2
  }
}

dump_bridge_failure() {
  local scenario="$1"
  local scenario_dir="$2"
  local ready_file="$3"
  local reason="$4"
  printf '%s\n' "--- MCP bridge failure diagnostics ---" >&2
  printf 'reason: %s\n' "$reason" >&2
  printf 'scenario: %s\n' "$scenario" >&2
  printf 'scenario_dir: %s\n' "$scenario_dir" >&2
  printf 'ready_file: %s\n' "$ready_file" >&2
  printf 'bridge_pid: %s\n' "${bridge_pid:-<unset>}" >&2
  if [ -n "${bridge_pid:-}" ]; then
    if kill -0 "$bridge_pid" >/dev/null 2>&1; then
      printf '%s\n' "bridge process is still running" >&2
    else
      printf '%s\n' "bridge process is not running" >&2
    fi
  fi
  if [ -e "$ready_file" ]; then
    print_file_tail "ready file" "$ready_file"
  else
    printf '%s\n' "ready file is missing" >&2
  fi
  if [ -d "$scenario_dir" ]; then
    printf '%s\n' "--- scenario dir listing ---" >&2
    ls -la "$scenario_dir" >&2 || true
  fi
  print_file_tail "bridge stdout" "$scenario_dir/bridge.stdout"
  print_file_tail "bridge stderr" "$scenario_dir/bridge.stderr"
  print_runtime_context
  print_process_snapshot
  if [ -d "$scenario_dir" ]; then
    run_resolver_probe "$scenario_dir"
  fi
  printf '%s\n' "--- end MCP bridge failure diagnostics ---" >&2
}

stop_bridge() {
  if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" >/dev/null 2>&1; then
    kill "$bridge_pid" >/dev/null 2>&1 || true
    wait "$bridge_pid" >/dev/null 2>&1 || true
  fi
  bridge_pid=""
  bridge_url=""
  bridge_scenario_dir=""
  bridge_ready_file=""
}

start_bridge() {
  local scenario="$1"
  local scenario_dir project_root ready_file
  scenario_dir="$tmp_dir/$scenario"
  project_root="$scenario_dir/project"
  ready_file="$scenario_dir/ready.json"
  bridge_scenario_dir="$scenario_dir"
  bridge_ready_file="$ready_file"
  mkdir -p "$scenario_dir" || return
  cp -R tests/save_olean_project "$project_root" || return
  env ${bridge_env[@]+"${bridge_env[@]}"} python3 tests/mcp_http_bridge.py \
    --root "$project_root" \
    --server .lake/build/bin/lean-beam-mcp \
    --lean-cmd "$(command -v lean)" \
    --lean-plugin ".lake/build/lib/$(shared_lib_name)" \
    --ready-file "$ready_file" \
    > "$scenario_dir/bridge.stdout" \
    2> "$scenario_dir/bridge.stderr" &
  bridge_pid="$!"
  if ! bridge_url="$(wait_for_ready_url "$ready_file" "$bridge_ready_timeout")"; then
    dump_bridge_failure "$scenario" "$scenario_dir" "$ready_file" \
      "timed out waiting for bridge readiness"
    return 1
  fi
}

run_python_getfqdn_probe
run_step "build MCP server" lake build RunAt:shared lean-beam-mcp
mkdir -p "$npm_cache"

scenarios="${MCP_CONFORMANCE_SCENARIOS:-server-initialize ping tools-list}"
run_conformance_scenario() {
  local scenario="$1"
  local url
  local rc=0
  if ! start_bridge "$scenario"; then
    stop_bridge
    return 1
  fi
  url="$bridge_url"
  if [ -n "${MCP_CONFORMANCE_EXPECTED_FAILURES:-}" ]; then
    npm_config_cache="$npm_cache" npm_config_update_notifier=false \
      npx -y "$conformance_package" server \
      --url "$url" \
      --scenario "$scenario" \
      --expected-failures "$MCP_CONFORMANCE_EXPECTED_FAILURES" || rc=$?
  else
    npm_config_cache="$npm_cache" npm_config_update_notifier=false \
      npx -y "$conformance_package" server \
      --url "$url" \
      --scenario "$scenario" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    dump_bridge_failure "$scenario" "$bridge_scenario_dir" "$bridge_ready_file" \
      "conformance scenario failed with exit code $rc"
  fi
  stop_bridge
  return "$rc"
}

for scenario in $scenarios; do
  run_step "scenario: $scenario" run_conformance_scenario "$scenario"
done
