#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh
# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-beam-toolchain-compat}"
bundle_timeout="${BEAM_TOOLCHAIN_COMPAT_TIMEOUT:-600}"
keep_tmp_on_failure="${BEAM_TOOLCHAIN_COMPAT_KEEP_TMP_ON_FAILURE:-0}"
toolchain="${1:-}"
if [ -z "$toolchain" ]; then
  echo "usage: bash tests/test-beam-toolchain-compat.sh <toolchain>" >&2
  exit 1
fi
case "$bundle_timeout" in
  ''|*[!0-9]*)
    echo "invalid BEAM_TOOLCHAIN_COMPAT_TIMEOUT: $bundle_timeout" >&2
    exit 1
    ;;
esac

tmp_bundle_dir="$(mktemp -d /tmp/beam-toolchain-bundles-XXXXXX)"
tmp_env_root="$(mktemp -d /tmp/beam-toolchain-env-XXXXXX)"
build_stdout="$tmp_env_root/build.stdout"
build_stderr="$tmp_env_root/build.stderr"
bundle_stdout="$tmp_env_root/bundle-install.stdout"
bundle_stderr="$tmp_env_root/bundle-install.stderr"
toolchain_failed=false

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" beam-toolchain-bundles beam-toolchain-env
}

cleanup() {
  if [ "$toolchain_failed" = "true" ]; then
    case "$keep_tmp_on_failure" in
      1|true|True|TRUE|yes|Yes|YES|on|On|ON)
        echo "preserving toolchain compatibility temp roots after failure:" >&2
        echo "  bundle dir: $tmp_bundle_dir" >&2
        echo "  env root: $tmp_env_root" >&2
        return 0
        ;;
    esac
  fi
  expect_owned_tmp_dir "$tmp_bundle_dir"
  expect_owned_tmp_dir "$tmp_env_root"
  rm -rf -- "$tmp_bundle_dir" "$tmp_env_root"
}
trap cleanup EXIT

mkdir -p "$tmp_env_root/home" "$tmp_env_root/codex" "$tmp_env_root/claude"

tail_file() {
  local label="$1"
  local path="$2"
  if [ -s "$path" ]; then
    echo "--- $label: $path ---" >&2
    tail -n 120 "$path" >&2
  else
    echo "--- $label: $path is empty or missing ---" >&2
  fi
}

print_toolchain_context() {
  local label="$1"
  toolchain_failed=true
  echo "toolchain compatibility failure: $label" >&2
  echo "toolchain: $toolchain" >&2
  echo "bundle timeout: ${bundle_timeout}s" >&2
  echo "keep tmp on failure: $keep_tmp_on_failure" >&2
  echo "bundle dir: $tmp_bundle_dir" >&2
  echo "env root: $tmp_env_root" >&2
  echo "home: $tmp_env_root/home" >&2
  echo "codex home: $tmp_env_root/codex" >&2
  echo "claude home: $tmp_env_root/claude" >&2
  echo "platform: $(uname -a)" >&2
  tail_file "build stdout" "$build_stdout"
  tail_file "build stderr" "$build_stderr"
  tail_file "bundle stdout" "$bundle_stdout"
  tail_file "bundle stderr" "$bundle_stderr"
}

run_build() {
  if ! lake build beam-cli > "$build_stdout" 2> "$build_stderr"; then
    print_toolchain_context "beam-cli build failed"
    return 1
  fi
}

run_with_timeout() {
  local timeout="$1"
  local stdout_path="$2"
  local stderr_path="$3"
  shift 3
  python3 - "$timeout" "$stdout_path" "$stderr_path" "$@" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
stdout_path = sys.argv[2]
stderr_path = sys.argv[3]
cmd = sys.argv[4:]

with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
    proc = subprocess.Popen(cmd, stdout=out, stderr=err)
    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        print(f"timed out after {timeout}s: {' '.join(cmd)}", file=sys.stderr)
        sys.exit(124)
sys.exit(rc)
PY
}

run_bundle_install() {
  local rc=0
  (
    unset BEAM_HOME BEAM_CONTROL_DIR
    export HOME="$tmp_env_root/home"
    export CODEX_HOME="$tmp_env_root/codex"
    export CLAUDE_HOME="$tmp_env_root/claude"
    export BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir"
    run_with_timeout "$bundle_timeout" "$bundle_stdout" "$bundle_stderr" \
      ./.lake/build/bin/beam-cli bundle-install "$toolchain"
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    print_toolchain_context "bundle install failed"
    return "$rc"
  fi
}

run_step "build beam-cli" run_build
run_step "bundle install $toolchain" run_bundle_install
