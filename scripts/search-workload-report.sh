#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
playouts="${1:-100}"
base_seed="${2:-20260311}"
output_path="${3:-}"

cmd=(lake exe runAt-search-workload-report "$playouts" "$base_seed")

if [ -n "$output_path" ]; then
  mkdir -p "$(dirname "$output_path")"
  (
    cd "$repo_root"
    "${cmd[@]}" | tee "$output_path"
  )
else
  (
    cd "$repo_root"
    "${cmd[@]}"
  )
fi
