#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

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

wait_for_file() {
  local path="$1"
  local label="${2:-$path}"
  local timeout="${3:-60}"
  local delay="${4:-0.05}"
  case "$timeout" in
    ''|*[!0-9]*)
      echo "invalid timeout '$timeout' for $label" >&2
      return 1
      ;;
  esac
  local deadline=$((SECONDS + timeout))
  while [ ! -e "$path" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "timed out after ${timeout}s waiting for $label at $path" >&2
      return 1
    fi
    sleep "$delay"
  done
  return 0
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
