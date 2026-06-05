#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

beam_script="$PWD/scripts/lean-beam"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi

read_json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
value = data
for part in sys.argv[2].split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

read_json_text_field() {
  python3 - "$1" <<'PY'
import json, os, sys
payload = json.loads(os.environ["RUNAT_JSON_PAYLOAD"])
path = sys.argv[1]
if path == "ok" and "ok" not in payload:
    print("false" if payload.get("error") is not None else "true")
    raise SystemExit(0)
value = payload
try:
    for part in path.split("."):
        if isinstance(value, list):
            value = value[int(part)]
        else:
            value = value[part]
except (KeyError, IndexError, ValueError, TypeError):
    print("")
    raise SystemExit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

expect_file() {
  if [ ! -f "$1" ]; then
    echo "missing expected file: $1" >&2
    exit 1
  fi
}

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-wrapper-daemon-*|/tmp/runat-validate-*/tmp/beam-wrapper-daemon-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

expect_path_within_tmp_dir() {
  local path="$1"
  local root="$2"
  expect_owned_tmp_dir "$root"
  case "$path" in
    "$root"|"$root"/*)
      ;;
    *)
      echo "refusing to touch path outside temp root $root: $path" >&2
      exit 1
      ;;
  esac
}

remove_owned_tmp_tree() {
  local path="$1"
  expect_owned_tmp_dir "$path"
  rm -rf -- "$path"
}

remove_tmp_tree_within() {
  local path="$1"
  local root="$2"
  expect_path_within_tmp_dir "$path" "$root"
  rm -rf -- "$path"
}

wait_for_exit() {
  local pid="$1"
  local label="$2"
  local tries="${3:-60}"
  local delay="${4:-0.5}"
  local remaining="$tries"
  while [ "$remaining" -gt 0 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep "$delay"
    remaining=$((remaining - 1))
  done
  echo "timed out waiting for $label (pid $pid) to exit" >&2
  return 1
}

stop_hold_process() {
  if [ -n "$hold_pid" ]; then
    kill -INT "$hold_pid" > /dev/null 2>&1 || true
    if ! wait_for_exit "$hold_pid" "ensure --hold wrapper" 20 0.1; then
      kill "$hold_pid" > /dev/null 2>&1 || true
      wait "$hold_pid" 2>/dev/null || true
    else
      wait "$hold_pid" 2>/dev/null || true
    fi
    hold_pid=""
  fi
}

tmp1="$(mktemp -d /tmp/beam-wrapper-daemon-a-XXXXXX)"
tmp3="$(mktemp -d /tmp/beam-wrapper-daemon-c-XXXXXX)"
tmp9="$(mktemp -d /tmp/beam-wrapper-daemon-i-XXXXXX)"
busy_pid=""
hold_pid=""

cleanup() {
  stop_hold_process
  if [ -n "$busy_pid" ]; then
    kill "$busy_pid" > /dev/null 2>&1 || true
    wait "$busy_pid" 2>/dev/null || true
  fi
  "$beam_script" --root "$tmp1" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp3" shutdown > /dev/null 2>&1 || true
  "$beam_script" --root "$tmp9" shutdown > /dev/null 2>&1 || true
  remove_owned_tmp_tree "$tmp1"
  remove_owned_tmp_tree "$tmp3"
  remove_owned_tmp_tree "$tmp9"
}
trap cleanup EXIT

for tmp in "$tmp1" "$tmp3" "$tmp9"; do
  expect_owned_tmp_dir "$tmp"
  rsync -a tests/save_olean_project/ "$tmp"/
  remove_tmp_tree_within "$tmp/.beam" "$tmp"
  mkdir -p "$tmp/.beam"
done

"$beam_script" --root "$tmp9" ensure --hold > "$tmp9/hold.out" 2> "$tmp9/hold.err" &
hold_pid="$!"
hold_registry="$tmp9/.beam/beam-daemon.json"
for _ in $(seq 1 600); do
  if [ -s "$tmp9/hold.out" ] && [ -f "$hold_registry" ]; then
    break
  fi
  sleep 0.1
done
if [ ! -s "$tmp9/hold.out" ] || [ ! -f "$hold_registry" ]; then
  echo "expected ensure --hold to print an ensure response and create a registry" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
if ! kill -0 "$hold_pid" 2>/dev/null; then
  echo "expected ensure --hold wrapper process to remain alive" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
hold_json="$(cat "$tmp9/hold.out")"
if [ "$(RUNAT_JSON_PAYLOAD="$hold_json" read_json_text_field ok)" != "true" ]; then
  echo "expected ensure --hold response to succeed" >&2
  printf '%s\n' "$hold_json" >&2
  cat "$tmp9/hold.err" >&2
  exit 1
fi
stop_hold_process
"$beam_script" --root "$tmp9" shutdown > /dev/null

stale_lease_dir="$tmp9/.beam/wrapper-leases"
stale_lease="$stale_lease_dir/stale-dead-wrapper.lease"
mkdir -p "$stale_lease_dir"
pid_namespace="$(readlink /proc/self/ns/pid 2>/dev/null || true)"
LEASE_PATH="$stale_lease" PID_NAMESPACE="$pid_namespace" python3 - <<'PY'
import json, os

metadata = {
    "pid": 999999999,
    "pidNamespace": os.environ["PID_NAMESPACE"] or None,
    "createdAt": "test",
}
with open(os.environ["LEASE_PATH"], "w") as f:
    json.dump(metadata, f)
    f.write("\n")
PY

"$beam_script" --root "$tmp9" ensure lean > /dev/null
if [ -e "$stale_lease" ]; then
  echo "expected wrapper ensure to remove a stale same-namespace wrapper lease" >&2
  cat "$stale_lease" >&2
  exit 1
fi
"$beam_script" --root "$tmp9" shutdown > /dev/null

(
  cd "$tmp1"
  "$beam_script" ensure lean > /dev/null
)

reg1="$tmp1/.beam/beam-daemon.json"
expect_file "$reg1"

pid1="$(read_json_field "$reg1" pid)"
port1="$(read_json_field "$reg1" port)"
root1="$(read_json_field "$reg1" root)"
if [ "$root1" != "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$tmp1")" ]; then
  echo "wrapper registry root mismatch: expected $tmp1, got $root1" >&2
  exit 1
fi
if ! kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be alive" >&2
  exit 1
fi

(
  cd "$tmp3"
  collision_out="$(mktemp /tmp/beam-wrapper-port-collision-out-XXXXXX)"
  collision_err="$(mktemp /tmp/beam-wrapper-port-collision-err-XXXXXX)"
  if "$beam_script" --port "$port1" ensure lean >"$collision_out" 2>"$collision_err"; then
    echo "expected wrapper ensure to reject a port already serving another Beam root" >&2
    cat "$collision_out" >&2
    cat "$collision_err" >&2
    rm -f "$collision_out" "$collision_err"
    exit 1
  fi
  if ! grep -q 'already serves Beam root' "$collision_err"; then
    echo "expected port collision failure to name the existing Beam root" >&2
    cat "$collision_out" >&2
    cat "$collision_err" >&2
    rm -f "$collision_out" "$collision_err"
    exit 1
  fi
  if [ -f "$tmp3/.beam/beam-daemon.json" ]; then
    echo "expected port collision failure not to write a registry for the wrong endpoint" >&2
    cat "$tmp3/.beam/beam-daemon.json" >&2
    rm -f "$collision_out" "$collision_err"
    exit 1
  fi
  rm -f "$collision_out" "$collision_err"
)

stale_registry="$tmp3/.beam/beam-daemon.json"
REGISTRY_TEMPLATE="$reg1" STALE_REGISTRY="$stale_registry" STALE_ROOT="$tmp3" python3 - <<'PY'
import json
import os

with open(os.environ["REGISTRY_TEMPLATE"]) as f:
    data = json.load(f)
data["root"] = os.path.realpath(os.environ["STALE_ROOT"])
data["configHash"] = "stale-registry-test"
with open(os.environ["STALE_REGISTRY"], "w") as f:
    json.dump(data, f)
    f.write("\n")
PY

(
  cd "$tmp3"
  doctor_out="$("$beam_script" doctor lean)"
  if ! printf '%s\n' "$doctor_out" | grep -q 'daemon status: stale'; then
    echo "expected wrapper doctor to reject a stale registry whose endpoint serves another root" >&2
    printf '%s\n' "$doctor_out" >&2
    exit 1
  fi
  "$beam_script" shutdown > /dev/null
  if [ -f "$stale_registry" ]; then
    echo "expected wrapper shutdown to remove the stale registry" >&2
    cat "$stale_registry" >&2
    exit 1
  fi
)
if ! kill -0 "$pid1" 2>/dev/null; then
  echo "expected stale registry shutdown not to kill the real Beam daemon for tmp1" >&2
  exit 1
fi

busy_port_file="$(mktemp /tmp/beam-wrapper-busy-port-XXXXXX)"
python3 - "$busy_port_file" <<'PY' &
import http.server
import socketserver
import sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1], "w") as f:
        print(server.server_address[1], file=f, flush=True)
    server.serve_forever()
PY
busy_pid=$!
for _ in $(seq 1 100); do
  if [ -s "$busy_port_file" ]; then
    break
  fi
  if ! kill -0 "$busy_pid" 2>/dev/null; then
    echo "expected temporary busy-port server to stay alive" >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$busy_port_file" ]; then
  echo "timed out waiting for temporary busy-port server" >&2
  exit 1
fi
busy_port="$(cat "$busy_port_file")"

(
  cd "$tmp3"
  busy_out="$(mktemp /tmp/beam-wrapper-busy-port-out-XXXXXX)"
  busy_err="$(mktemp /tmp/beam-wrapper-busy-port-err-XXXXXX)"
  if "$beam_script" --port "$busy_port" ensure lean >"$busy_out" 2>"$busy_err"; then
    echo "expected wrapper ensure to reject a port already used by a non-Beam process" >&2
    cat "$busy_out" >&2
    cat "$busy_err" >&2
    rm -f "$busy_out" "$busy_err"
    exit 1
  fi
  if ! grep -q 'already in use' "$busy_err"; then
    echo "expected non-Beam port collision failure to report the occupied endpoint" >&2
    cat "$busy_out" >&2
    cat "$busy_err" >&2
    rm -f "$busy_out" "$busy_err"
    exit 1
  fi
  if [ -f "$tmp3/.beam/beam-daemon.json" ]; then
    echo "expected non-Beam port collision failure not to write a registry" >&2
    cat "$tmp3/.beam/beam-daemon.json" >&2
    rm -f "$busy_out" "$busy_err"
    exit 1
  fi
  rm -f "$busy_out" "$busy_err"
)
kill "$busy_pid" > /dev/null 2>&1 || true
wait "$busy_pid" 2>/dev/null || true
busy_pid=""
rm -f "$busy_port_file"
