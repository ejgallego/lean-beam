#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-broker-slow}"

tmp_bundle_dir="$(mktemp -d /tmp/beam-daemon-bundles-XXXXXX)"
tmp_env_root="$(mktemp -d /tmp/beam-daemon-env-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-daemon-bundles-*|/tmp/beam-daemon-env-*|/tmp/runat-validate-*/tmp/beam-daemon-bundles-*|/tmp/runat-validate-*/tmp/beam-daemon-env-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

remove_owned_tmp_tree() {
  local path="$1"
  expect_owned_tmp_dir "$path"
  rm -rf -- "$path"
}

cleanup() {
  remove_owned_tmp_tree "$tmp_bundle_dir"
  remove_owned_tmp_tree "$tmp_env_root"
}
trap cleanup EXIT

mkdir -p "$tmp_env_root/home" "$tmp_env_root/codex" "$tmp_env_root/claude"

toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"
# Fake agent homes isolate install state; the wrapper still needs the host Lean toolchain cache.
host_elan_home="${ELAN_HOME:-$HOME/.elan}"

run_step "shell lint" bash scripts/lint-shell.sh

run_step "build" lake build \
  RunAt:shared \
  beam-cli \
  beam-daemon \
  beam-client \
  lean-beam-mcp

run_step "MCP stdio stress" python3 tests/test-mcp-stdio.py --iterations 4 --restart-cycles 3

run_step "bundle install" env BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
  ./.lake/build/bin/beam-cli bundle-install "$toolchain"

run_step "wrapper daemon tests" env \
  HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  ELAN_HOME="$host_elan_home" BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
  bash tests/test-beam-wrapper-daemon.sh

run_step "wrapper tests" env \
  HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  ELAN_HOME="$host_elan_home" BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
  bash tests/test-beam-wrapper.sh

if [ "$(uname -s)" = "Linux" ]; then
  run_step "sandbox wrapper tests" env \
    HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
    ELAN_HOME="$host_elan_home" BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
    bash tests/test-beam-wrapper-sandbox.sh
fi

run_step "save replay tests" env \
  HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  ELAN_HOME="$host_elan_home" BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
  bash tests/test-broker-save-olean.sh
