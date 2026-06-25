#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd)"
primary_root="$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')"

# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh

tmp_root="$(mktemp -d /tmp/runat-codex-harness-XXXXXX)"

override_root_parent="$repo_root/.codex-worktrees/test-codex-harness-$$"
export RUNAT_CODEX_WORKTREE_ROOT="$override_root_parent/worktrees"
task_id="test-codex-harness-$$"
task_slug="${task_id}"
worktree_path="$RUNAT_CODEX_WORKTREE_ROOT/$task_slug"
default_home="$tmp_root/default-home"
default_root="$repo_root/.codex-worktrees/lean-beam"
default_task_id="test-codex-harness-default-$$"
default_task_slug="${default_task_id}"
default_worktree_path="$default_root/$default_task_slug"

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" runat-codex-harness
}

remove_owned_tmp_tree() {
  local path="$1"
  beam_test_remove_owned_tmp_tree "$path" runat-codex-harness
}

remove_owned_repo_tree() {
  local path="$1"
  case "$path" in
    "$repo_root"/.codex-worktrees/test-codex-harness-*)
      rm -rf -- "$path"
      ;;
    *)
      echo "refusing to touch unexpected repo-local harness dir: $path" >&2
      exit 1
      ;;
  esac
}

cleanup() {
  if [ -d "$worktree_path" ]; then
    git worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  fi
  if git show-ref --verify --quiet "refs/heads/codex/$task_slug"; then
    git branch -D "codex/$task_slug" >/dev/null 2>&1 || true
  fi
  if [ -d "$default_worktree_path" ]; then
    git worktree remove --force "$default_worktree_path" >/dev/null 2>&1 || true
  fi
  if git show-ref --verify --quiet "refs/heads/codex/$default_task_slug"; then
    git branch -D "codex/$default_task_slug" >/dev/null 2>&1 || true
  fi
  if [ -d "$override_root_parent" ]; then
    remove_owned_repo_tree "$override_root_parent"
  fi
  remove_owned_tmp_tree "$tmp_root"
}
trap cleanup EXIT

session_out="$(./scripts/codex-harness.sh session start "$task_id")"
if ! printf '%s\n' "$session_out" | grep -q "$worktree_path"; then
  echo "expected session start to print the dedicated worktree path" >&2
  printf '%s\n' "$session_out" >&2
  exit 1
fi

if [ ! -d "$worktree_path/.git" ] && [ ! -f "$worktree_path/.git" ]; then
  echo "expected dedicated worktree to be created at $worktree_path" >&2
  exit 1
fi

mkdir -p "$default_home"
default_session_out="$(env -u RUNAT_CODEX_WORKTREE_ROOT HOME="$default_home" ./scripts/codex-harness.sh session start "$default_task_id")"
if ! printf '%s\n' "$default_session_out" | grep -q "$default_worktree_path"; then
  echo "expected session start without RUNAT_CODEX_WORKTREE_ROOT to use the repo-local default" >&2
  printf '%s\n' "$default_session_out" >&2
  exit 1
fi

if [ ! -d "$default_worktree_path/.git" ] && [ ! -f "$default_worktree_path/.git" ]; then
  echo "expected default dedicated worktree to be created at $default_worktree_path" >&2
  exit 1
fi

worktree_session_out="$(cd "$worktree_path" && "$repo_root/scripts/codex-session-start.sh")"
if ! printf '%s\n' "$worktree_session_out" | grep -q 'worktree discipline: dedicated task checkout'; then
  echo "expected codex-session-start inside a task worktree to report dedicated checkout status" >&2
  printf '%s\n' "$worktree_session_out" >&2
  exit 1
fi

primary_err="$tmp_root/primary.err"
if (
  cd "$primary_root"
  "$repo_root/scripts/codex-session-start.sh" >"$tmp_root/primary.out" 2>"$primary_err"
); then
  echo "expected codex-session-start in the primary checkout to fail without override" >&2
  exit 1
fi

if ! grep -q 'use ./scripts/codex-harness.sh session start <task-id> instead' "$primary_err"; then
  echo "expected primary checkout refusal to include the worktree guidance" >&2
  cat "$primary_err" >&2
  exit 1
fi

unsafe_root_err="$tmp_root/unsafe-root.err"
if RUNAT_CODEX_WORKTREE_ROOT="/" ./scripts/codex-harness.sh worktree add "unsafe-root-$$" >"$tmp_root/unsafe-root.out" 2>"$unsafe_root_err"; then
  echo "expected harness to reject / as RUNAT_CODEX_WORKTREE_ROOT" >&2
  exit 1
fi

if ! grep -q 'RUNAT_CODEX_WORKTREE_ROOT must not be /' "$unsafe_root_err"; then
  echo "expected unsafe worktree root refusal to mention / explicitly" >&2
  cat "$unsafe_root_err" >&2
  exit 1
fi

outside_root_err="$tmp_root/outside-root.err"
if RUNAT_CODEX_WORKTREE_ROOT="$tmp_root/outside-repo" ./scripts/codex-harness.sh worktree add "outside-root-$$" >"$tmp_root/outside-root.out" 2>"$outside_root_err"; then
  echo "expected harness to reject RUNAT_CODEX_WORKTREE_ROOT outside the repo" >&2
  exit 1
fi

if ! grep -q 'RUNAT_CODEX_WORKTREE_ROOT must be inside the repo root' "$outside_root_err"; then
  echo "expected outside worktree root refusal to mention the repo-root requirement" >&2
  cat "$outside_root_err" >&2
  exit 1
fi
