#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

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

sed_in_place_portable() {
  local expr="$1"
  local path="$2"
  local tmp
  tmp="$(mktemp "${path}.sed-XXXXXX")"
  sed "$expr" "$path" >"$tmp"
  mv "$tmp" "$path"
}

read_json_array_len() {
  python3 - "$1" <<'PY'
import json, os, sys
payload = json.loads(os.environ["RUNAT_JSON_PAYLOAD"])
value = payload
for part in sys.argv[1].split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]
print(len(value))
PY
}

json_text_field() {
  local payload="$1"
  local field="$2"
  RUNAT_JSON_PAYLOAD="$payload" read_json_text_field "$field"
}

json_array_len() {
  local payload="$1"
  local field="$2"
  RUNAT_JSON_PAYLOAD="$payload" read_json_array_len "$field"
}

json_file_text_field() {
  local payload_file="$1"
  local field="$2"
  RUNAT_JSON_PAYLOAD="$(cat "$payload_file")" read_json_text_field "$field"
}

json_file_array_len() {
  local payload_file="$1"
  local field="$2"
  RUNAT_JSON_PAYLOAD="$(cat "$payload_file")" read_json_array_len "$field"
}

print_json_file_assertion_context() {
  local payload_file="$1"
  local context_file
  shift
  cat "$payload_file" >&2
  for context_file in "$@"; do
    if [ -f "$context_file" ]; then
      cat "$context_file" >&2
    fi
  done
}

assert_json_field_equals() {
  local label="$1"
  local payload="$2"
  local field="$3"
  local expected="$4"
  local actual
  actual="$(json_text_field "$payload" "$field")"
  if [ "$actual" != "$expected" ]; then
    echo "expected $label to report $field = $expected, got ${actual:-<empty>}" >&2
    printf '%s\n' "$payload" >&2
    exit 1
  fi
}

assert_json_file_field_equals() {
  local label="$1"
  local payload_file="$2"
  local field="$3"
  local expected="$4"
  local actual
  shift 4
  actual="$(json_file_text_field "$payload_file" "$field")"
  if [ "$actual" != "$expected" ]; then
    echo "expected $label to report $field = $expected, got ${actual:-<empty>}" >&2
    print_json_file_assertion_context "$payload_file" "$@"
    exit 1
  fi
}

assert_json_field_nonempty() {
  local label="$1"
  local payload="$2"
  local field="$3"
  local actual
  actual="$(json_text_field "$payload" "$field")"
  if [ -z "$actual" ]; then
    echo "expected $label to report a non-empty $field" >&2
    printf '%s\n' "$payload" >&2
    exit 1
  fi
}

assert_json_field_int_ge() {
  local label="$1"
  local payload="$2"
  local field="$3"
  local minimum="$4"
  local actual
  actual="$(json_text_field "$payload" "$field")"
  case "$actual" in
    ""|*[!0-9]*)
      echo "expected $label to report numeric $field >= $minimum, got ${actual:-<empty>}" >&2
      printf '%s\n' "$payload" >&2
      exit 1
      ;;
  esac
  if [ "${actual:-0}" -lt "$minimum" ]; then
    echo "expected $label to report $field >= $minimum, got ${actual:-<empty>}" >&2
    printf '%s\n' "$payload" >&2
    exit 1
  fi
}

assert_json_array_len_equals() {
  local label="$1"
  local payload="$2"
  local field="$3"
  local expected="$4"
  local actual
  actual="$(json_array_len "$payload" "$field")"
  if [ "$actual" != "$expected" ]; then
    echo "expected $label to report $field length = $expected, got ${actual:-<empty>}" >&2
    printf '%s\n' "$payload" >&2
    exit 1
  fi
}

assert_json_file_array_len_equals() {
  local label="$1"
  local payload_file="$2"
  local field="$3"
  local expected="$4"
  local actual
  shift 4
  actual="$(json_file_array_len "$payload_file" "$field")"
  if [ "$actual" != "$expected" ]; then
    echo "expected $label to report $field length = $expected, got ${actual:-<empty>}" >&2
    print_json_file_assertion_context "$payload_file" "$@"
    exit 1
  fi
}

expect_file() {
  if [ ! -f "$1" ]; then
    echo "missing expected file: $1" >&2
    exit 1
  fi
}

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-wrapper-*|/tmp/runat-validate-*/tmp/beam-wrapper-*)
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

wait_for_nonempty_file() {
  local path="$1"
  local label="$2"
  local tries="${3:-120}"
  local delay="${4:-0.1}"
  local remaining="$tries"
  while [ "$remaining" -gt 0 ]; do
    if [ -s "$path" ]; then
      return 0
    fi
    sleep "$delay"
    remaining=$((remaining - 1))
  done
  echo "timed out waiting for $label to write $path" >&2
  return 1
}

wait_for_file_text() {
  local path="$1"
  local text="$2"
  local label="$3"
  local tries="${4:-120}"
  local delay="${5:-0.1}"
  local remaining="$tries"
  while [ "$remaining" -gt 0 ]; do
    if [ -f "$path" ] && grep -F -q -- "$text" "$path"; then
      return 0
    fi
    sleep "$delay"
    remaining=$((remaining - 1))
  done
  echo "timed out waiting for $label in $path" >&2
  return 1
}
