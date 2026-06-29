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
stale_project_root="$tmp_env_root/stale-diagnostic-project"
stale_build_stdout="$tmp_env_root/stale-build.stdout"
stale_build_stderr="$tmp_env_root/stale-build.stderr"
stale_sync_stdout="$tmp_env_root/stale-sync.stdout"
stale_sync_stderr="$tmp_env_root/stale-sync.stderr"
toolchain_failed=false

if [ -z "${ELAN_HOME:-}" ] && [ -d "$HOME/.elan" ]; then
  export ELAN_HOME="$HOME/.elan"
fi
host_elan_home="${ELAN_HOME:-$HOME/.elan}"

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" beam-toolchain-bundles beam-toolchain-env
}

cleanup() {
  if [ -n "${stale_project_root:-}" ] && [ -d "$stale_project_root" ]; then
    HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
      ELAN_HOME="$host_elan_home" BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
      ./scripts/lean-beam --root "$stale_project_root" shutdown > /dev/null 2>&1 || true
  fi
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
  tail_file "stale build stdout" "$stale_build_stdout"
  tail_file "stale build stderr" "$stale_build_stderr"
  tail_file "stale sync stdout" "$stale_sync_stdout"
  tail_file "stale sync stderr" "$stale_sync_stderr"
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

prepare_stale_diagnostic_project() {
  rm -rf -- "$stale_project_root"
  mkdir -p "$stale_project_root"
  cp -R tests/save_olean_project/. "$stale_project_root"/
  printf '%s\n' "$toolchain" > "$stale_project_root/lean-toolchain"
  rm -rf -- "$stale_project_root/.beam"
  mkdir -p "$stale_project_root/.beam"
}

assert_stale_diagnostic_payload() {
  python3 - "$stale_sync_stdout" <<'PY'
import json
import sys

expected = 'Imports are out of date and should be rebuilt; use the "Restart File" command in your editor.'
path = sys.argv[1]
try:
    with open(path) as f:
        payload = json.load(f)
except Exception as ex:
    raise SystemExit(f"expected stale sync stdout to be JSON, got {ex}")

error = payload.get("error")
if not isinstance(error, dict):
    raise SystemExit(f"expected stale sync response to be an error, got {payload!r}")
if error.get("code") != "syncBarrierIncomplete":
    raise SystemExit(f"expected syncBarrierIncomplete, got {error.get('code')!r}")
data = error.get("data")
if not isinstance(data, dict):
    raise SystemExit(f"expected error.data object, got {data!r}")
diagnostics = data.get("completionBlockingDiagnostics")
if not isinstance(diagnostics, list):
    raise SystemExit(f"expected completionBlockingDiagnostics array, got {diagnostics!r}")
messages = [diag.get("message") for diag in diagnostics if isinstance(diag, dict)]
if expected not in messages:
    raise SystemExit(
        "expected Lean stale-import diagnostic wording in completionBlockingDiagnostics; "
        f"messages were {messages!r}"
    )
PY
}

run_stale_wrapper() {
  env \
    HOME="$tmp_env_root/home" \
    CODEX_HOME="$tmp_env_root/codex" \
    CLAUDE_HOME="$tmp_env_root/claude" \
    ELAN_HOME="$host_elan_home" \
    BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir" \
    ./scripts/lean-beam --root "$stale_project_root" "$@"
}

run_stale_wrapper_checked() {
  local label="$1"
  shift
  if ! run_stale_wrapper "$@" > "$stale_sync_stdout" 2> "$stale_sync_stderr"; then
    print_toolchain_context "$label"
    return 1
  fi
}

run_stale_diagnostic_compat() {
  local rc=0
  prepare_stale_diagnostic_project
  cat > "$stale_project_root/SaveSmoke/B.lean" <<'EOF'
def old : Nat := 1
EOF
  cat > "$stale_project_root/SaveSmoke/A.lean" <<'EOF'
import SaveSmoke.B

def aVal : Nat := old
EOF
  (
    cd "$stale_project_root"
    lake build SaveSmoke/A.lean > "$stale_build_stdout" 2> "$stale_build_stderr"
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    print_toolchain_context "stale diagnostic fixture build failed"
    return "$rc"
  fi

  if ! run_stale_wrapper_checked "initial dependency sync failed" sync SaveSmoke/B.lean; then
    return 1
  fi
  if ! run_stale_wrapper_checked "initial importer sync failed" sync SaveSmoke/A.lean; then
    return 1
  fi

  cat > "$stale_project_root/SaveSmoke/B.lean" <<'EOF'
def new : Nat := 2
EOF
  cat > "$stale_project_root/SaveSmoke/A.lean" <<'EOF'
import SaveSmoke.B

def aVal : Nat := new
EOF
  if ! run_stale_wrapper_checked "changed dependency sync failed" sync SaveSmoke/B.lean; then
    return 1
  fi
  if ! run_stale_wrapper_checked "changed dependency save failed" save SaveSmoke/B.lean; then
    return 1
  fi
  (
    cd "$stale_project_root"
    lake build SaveSmoke/A.lean > "$stale_build_stdout" 2> "$stale_build_stderr"
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    print_toolchain_context "changed stale diagnostic fixture build failed"
    return "$rc"
  fi

  rc=0
  run_stale_wrapper sync SaveSmoke/A.lean > "$stale_sync_stdout" 2> "$stale_sync_stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    print_toolchain_context "stale diagnostic sync unexpectedly succeeded"
    return 1
  fi
  if ! assert_stale_diagnostic_payload; then
    print_toolchain_context "stale diagnostic wording changed"
    return 1
  fi
}

run_step "build beam-cli" run_build
run_step "bundle install $toolchain" run_bundle_install
run_step "stale diagnostic wording $toolchain" run_stale_diagnostic_compat
