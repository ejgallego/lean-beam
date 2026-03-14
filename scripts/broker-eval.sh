#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
beam="$repo_root/scripts/beam"

if [ ! -x "$beam" ]; then
  echo "missing beam wrapper at $beam" >&2
  echo "run: lake build beam-cli" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
usage:
  scripts/broker-eval.sh case-a <lean-root>
  scripts/broker-eval.sh report <root>
  scripts/broker-eval.sh reset <root>
  scripts/broker-eval.sh shutdown <root>
EOF
}

ensure_abs_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "directory does not exist: $dir" >&2
    exit 1
  fi
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dir"
}

case "${1:-}" in
  case-a)
    if [ $# -ne 2 ]; then
      usage >&2
      exit 1
    fi
    lean_root="$(ensure_abs_dir "$2")"
    "$beam" --root "$lean_root" ensure lean > /dev/null
    "$beam" --root "$lean_root" reset-stats > /dev/null
    cat <<EOF
Beam daemon stats reset.
Lean backend ensured at:
  $lean_root

Run your workflow now, then collect stats with:
  scripts/broker-eval.sh report $lean_root
EOF
    ;;
  report)
    if [ $# -ne 2 ]; then
      usage >&2
      exit 1
    fi
    root="$(ensure_abs_dir "$2")"
    "$beam" --root "$root" stats
    ;;
  reset)
    if [ $# -ne 2 ]; then
      usage >&2
      exit 1
    fi
    root="$(ensure_abs_dir "$2")"
    "$beam" --root "$root" reset-stats
    ;;
  shutdown)
    if [ $# -ne 2 ]; then
      usage >&2
      exit 1
    fi
    root="$(ensure_abs_dir "$2")"
    "$beam" --root "$root" shutdown
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
