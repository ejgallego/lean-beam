#!/usr/bin/env bash
set -euo pipefail

# Maintainer workflow helper for this repository.
# This script is intentionally local contributor tooling, not part of the public runAt interface.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKTREE_ROOT="${RUNAT_CODEX_WORKTREE_ROOT:-/tmp/runat-codex-worktrees}"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/codex-harness.sh session start <task-id> [base-ref]
  ./scripts/codex-harness.sh worktree add <task-id> [base-ref]
  ./scripts/codex-harness.sh worktree list
  ./scripts/codex-harness.sh worktree drop <task-id>

Environment:
  RUNAT_CODEX_WORKTREE_ROOT
  RUNAT_CODEX_ALLOW_PRIMARY_WORKTREE=1   Allow session-start in the primary checkout

Note:
  This is maintainer workflow tooling for this repo. It is not part of the public runAt CLI.
EOF
}

primary_root() {
  git -C "${REPO_ROOT}" worktree list --porcelain | awk '/^worktree / { print $2; exit }'
}

sanitize_task_id() {
  local task_id="$1"
  local slug
  slug="$(printf '%s' "${task_id}" | tr '/[:space:]' '-' | tr -cd '[:alnum:]._-')"
  [[ -n "${slug}" ]] || die "task id must contain at least one alphanumeric character"
  printf '%s\n' "${slug}"
}

branch_name_for() {
  printf 'codex/%s\n' "$1"
}

worktree_path_for() {
  printf '%s/%s\n' "${WORKTREE_ROOT}" "$1"
}

ensure_primary_tracked_clean() {
  local tracked_status
  tracked_status="$(git -C "$(primary_root)" status --short --untracked-files=no)"
  [[ -z "${tracked_status}" ]] || die \
    "primary checkout has tracked edits; move or commit them before starting a new task worktree"
}

ensure_worktree_root() {
  mkdir -p "${WORKTREE_ROOT}"
}

add_worktree() {
  local task_id="$1"
  local base_ref="${2:-main}"
  local slug branch path
  slug="$(sanitize_task_id "${task_id}")"
  branch="$(branch_name_for "${slug}")"
  path="$(worktree_path_for "${slug}")"

  ensure_primary_tracked_clean
  ensure_worktree_root

  if [[ -d "${path}" ]]; then
    printf '%s\n' "${path}"
    return
  fi

  if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "${REPO_ROOT}" worktree add "${path}" "${branch}" >/dev/null
  else
    git -C "${REPO_ROOT}" worktree add -b "${branch}" "${path}" "${base_ref}" >/dev/null
  fi
  printf '%s\n' "${path}"
}

drop_worktree() {
  local task_id="$1"
  local slug branch path
  slug="$(sanitize_task_id "${task_id}")"
  branch="$(branch_name_for "${slug}")"
  path="$(worktree_path_for "${slug}")"

  [[ -d "${path}" ]] || die "unknown worktree path: ${path}"
  git -C "${REPO_ROOT}" worktree remove "${path}" >/dev/null
  if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "${REPO_ROOT}" branch -D "${branch}" >/dev/null
  fi
}

list_worktrees() {
  git -C "${REPO_ROOT}" worktree list
}

session_start() {
  local task_id="$1"
  local base_ref="${2:-main}"
  local path
  path="$(add_worktree "${task_id}" "${base_ref}")"
  (
    cd "${path}"
    "${SCRIPT_DIR}/codex-session-start.sh"
  )
  printf '%s\n' "${path}"
}

main() {
  [[ "$#" -gt 0 ]] || {
    usage
    exit 1
  }

  case "$1" in
    session)
      [[ "${2:-}" == "start" ]] || die "usage: ./scripts/codex-harness.sh session start <task-id> [base-ref]"
      [[ -n "${3:-}" ]] || die "missing task id"
      session_start "$3" "${4:-main}"
      ;;
    worktree)
      case "${2:-}" in
        add)
          [[ -n "${3:-}" ]] || die "missing task id"
          add_worktree "$3" "${4:-main}"
          ;;
        list)
          list_worktrees
          ;;
        drop)
          [[ -n "${3:-}" ]] || die "missing task id"
          drop_worktree "$3"
          ;;
        *)
          die "usage: ./scripts/codex-harness.sh worktree {add|list|drop} ..."
          ;;
      esac
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $1"
      ;;
  esac
}

main "$@"
