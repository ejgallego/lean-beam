#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

run_step() {
  local label="$1"
  shift
  local start
  local end
  local rc

  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::group::%s\n' "$label"
  fi
  start="$(date +%s)"
  printf '[%s] %s\n' "${BEAM_TEST_SUITE:-beam-test}" "$label"

  set +e
  "$@"
  rc=$?
  set -e

  end="$(date +%s)"
  printf '[%s] %s finished in %ss\n' "${BEAM_TEST_SUITE:-beam-test}" "$label" "$((end - start))"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::endgroup::\n'
  fi

  return "$rc"
}
