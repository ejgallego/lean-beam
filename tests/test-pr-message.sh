#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh

tmp_root="$(mktemp -d /tmp/beam-pr-message-XXXXXX)"
beam_test_expect_owned_tmp_dir "$tmp_root" beam-pr-message
cleanup() {
  beam_test_remove_owned_tmp_tree "$tmp_root" beam-pr-message
}
trap cleanup EXIT

fixture_repo="$tmp_root/repo"
mkdir -p "$fixture_repo/scripts"
cp scripts/pr-message.sh "$fixture_repo/scripts/pr-message.sh"
git init -q -b main "$fixture_repo"
git -C "$fixture_repo" config user.name "Beam Test"
git -C "$fixture_repo" config user.email "beam-test@example.com"
printf 'base\n' >"$fixture_repo/README.md"
git -C "$fixture_repo" add README.md
git -C "$fixture_repo" commit -q -m "chore: establish fixture base"
git -C "$fixture_repo" switch -q -c topic

if "$fixture_repo/scripts/pr-message.sh" >"$tmp_root/no-commit.out" 2>"$tmp_root/no-commit.err"; then
  echo "expected default PR title to reject a branch without commits beyond main" >&2
  exit 1
fi
grep -q 'HEAD has no commits beyond main' "$tmp_root/no-commit.err"

printf 'dirty\n' >>"$fixture_repo/README.md"
if "$fixture_repo/scripts/pr-message.sh" >"$tmp_root/dirty.out" 2>"$tmp_root/dirty.err"; then
  echo "expected default PR title to reject tracked changes" >&2
  exit 1
fi
grep -q 'tracked changes are present' "$tmp_root/dirty.err"

git -C "$fixture_repo" add README.md
git -C "$fixture_repo" commit -q -m "fix: stale inherited title (#237)"
if "$fixture_repo/scripts/pr-message.sh" >"$tmp_root/suffix.out" 2>"$tmp_root/suffix.err"; then
  echo "expected default PR title to reject an existing PR-number suffix" >&2
  exit 1
fi
grep -q 'commit subject ending in a PR number' "$tmp_root/suffix.err"

git -C "$fixture_repo" commit -q --amend -m "fix: guard PR title defaults"
default_out="$("$fixture_repo/scripts/pr-message.sh")"
printf '%s\n' "$default_out" | grep -q '^pr_title=fix: guard PR title defaults$'

printf 'more work\n' >>"$fixture_repo/README.md"
explicit_out="$("$fixture_repo/scripts/pr-message.sh" \
  --title "fix: describe staged work" \
  --summary "This PR describes the staged work explicitly.")"
printf '%s\n' "$explicit_out" | grep -q '^pr_title=fix: describe staged work$'
printf '%s\n' "$explicit_out" | grep -q '^This PR describes the staged work explicitly\.$'
