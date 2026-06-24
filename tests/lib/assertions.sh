#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

assert_output_contains() {
  local label="$1"
  local output="$2"
  local expected="$3"
  if ! grep -Fq -- "$expected" <<< "$output"; then
    echo "expected $label to contain: $expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_output_not_contains() {
  local label="$1"
  local output="$2"
  local unexpected="$3"
  if grep -Fq -- "$unexpected" <<< "$output"; then
    echo "expected $label not to contain: $unexpected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "missing file: $path" >&2
    exit 1
  fi
}

assert_not_exists() {
  local path="$1"
  if [ -e "$path" ]; then
    echo "expected path to be absent: $path" >&2
    exit 1
  fi
}

assert_contains() {
  local path="$1"
  local pattern="$2"
  if ! grep -q "$pattern" "$path"; then
    echo "expected $path to contain pattern: $pattern" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_contains_literal() {
  local path="$1"
  local pattern="$2"
  if ! grep -Fq "$pattern" "$path"; then
    echo "expected $path to contain literal: $pattern" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  if grep -q "$pattern" "$path"; then
    echo "expected $path not to contain pattern: $pattern" >&2
    cat "$path" >&2
    exit 1
  fi
}
