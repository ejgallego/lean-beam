#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/assertions.sh
. tests/lib/assertions.sh

toolchain="${BEAM_STAGE0_TOOLCHAIN:-lean4-stage0}"
host_home="$HOME"
host_elan_home="${ELAN_HOME:-$host_home/.elan}"

if [ ! -d "$host_elan_home" ]; then
  echo "skip: no host elan home found for $toolchain; set ELAN_HOME to run this smoke" >&2
  exit 0
fi

if ! ELAN_HOME="$host_elan_home" elan run "$toolchain" lean --version >/dev/null 2>&1; then
  echo "skip: elan toolchain is not available: $toolchain" >&2
  exit 0
fi

tmp_root="$(mktemp -d /tmp/beam-stage0-smoke-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-stage0-smoke-*|/tmp/runat-validate-*/tmp/beam-stage0-smoke-*)
      ;;
    *)
      echo "refusing to touch unexpected temp dir: $1" >&2
      exit 1
      ;;
  esac
}

cleanup() {
  expect_owned_tmp_dir "$tmp_root"
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

install_home="$tmp_root/home"
install_root="$tmp_root/install-root"
project_root="$tmp_root/project"
doctor_out=""

mkdir -p "$install_home" "$install_root"

HOME="$install_home" \
  ELAN_HOME="$host_elan_home" \
  BEAM_INSTALL_ROOT="$install_root" \
  bash scripts/install-beam.sh --dont-ask --custom-toolchain "$toolchain" >/dev/null

rsync -a tests/save_olean_project/ "$project_root"/
printf '%s\n' "$toolchain" > "$project_root/lean-toolchain"

doctor_out="$(ELAN_HOME="$host_elan_home" \
  "$install_home/.local/bin/lean-beam" --root "$project_root" doctor)"

assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" 'project toolchain supported: false'
assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" 'project toolchain custom: true'
assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" 'project toolchain accepted: true'
assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" 'bundle source: installed'
assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" 'bundle toolchain fingerprint: '

ELAN_HOME="$host_elan_home" \
  "$install_home/.local/bin/lean-beam" --root "$project_root" ensure >/dev/null
ELAN_HOME="$host_elan_home" \
  "$install_home/.local/bin/lean-beam" --root "$project_root" shutdown >/dev/null
