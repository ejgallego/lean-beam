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
