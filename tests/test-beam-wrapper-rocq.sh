#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

beam_script="$PWD/scripts/lean-beam"
rocq_cmd="${BEAM_ROCQ_CMD:-}"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi

if [ -z "$rocq_cmd" ]; then
  echo "missing BEAM_ROCQ_CMD for Rocq wrapper test" >&2
  exit 1
fi

tmp_repo="$(mktemp -d /tmp/beam-wrapper-rocq-XXXXXX)"

expect_owned_tmp_dir() {
  case "$1" in
    /tmp/beam-wrapper-rocq-*|/tmp/runat-validate-*/tmp/beam-wrapper-rocq-*)
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
  if [ -d "$tmp_repo/tests/rocq/Minimal" ]; then
    BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null 2>&1 || true
  fi
  remove_owned_tmp_tree "$tmp_repo"
}
trap cleanup EXIT

rsync -a \
  --exclude='.git/' \
  --exclude='.lake/' \
  --exclude='.beam/' \
  --exclude='_opam/' \
  "$PWD"/ "$tmp_repo"/

(
  cd "$tmp_repo"
  lake build beam-cli > /dev/null
  if [ -x ".lake/build/bin/beam-daemon" ] || [ -x ".lake/build/bin/beam-client" ]; then
    echo "expected lake build beam-cli not to prebuild Beam daemon helper executables" >&2
    exit 1
  fi
  BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" doctor rocq > /dev/null
  if [ -x ".lake/build/bin/beam-daemon" ] || [ -x ".lake/build/bin/beam-client" ]; then
    echo "expected doctor rocq to remain read-only and not build Beam daemon helpers" >&2
    exit 1
  fi
  BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" ensure rocq > /dev/null
  if [ ! -x ".lake/build/bin/beam-daemon" ] || [ ! -x ".lake/build/bin/beam-client" ]; then
    echo "expected rocq CLI startup to build missing Beam daemon helpers on demand" >&2
    exit 1
  fi
  BEAM_ROCQ_CMD="$rocq_cmd" "$tmp_repo/scripts/lean-beam" --root "$tmp_repo/tests/rocq/Minimal" shutdown > /dev/null
)
