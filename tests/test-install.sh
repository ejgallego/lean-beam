#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

export HOME="$tmp_root/home"
export CODEX_HOME="$tmp_root/codex"
export CLAUDE_HOME="$tmp_root/claude"
export RUNAT_INSTALL_ROOT="$tmp_root/install-root"

mkdir -p "$HOME" "$CODEX_HOME" "$CLAUDE_HOME" "$RUNAT_INSTALL_ROOT"

toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"
source_checkout="$tmp_root/source-checkout"

assert_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "missing file: $path" >&2
    exit 1
  fi
}

assert_no_skill_socket_guidance() {
  local skill_doc="$1"
  if rg -n -- '--socket|Unix domain socket|unix domain socket' "$skill_doc" > /dev/null; then
    echo "unexpected socket guidance in installed skill: $skill_doc" >&2
    exit 1
  fi
}

assert_symlink_target() {
  local path="$1"
  local expected="$2"
  local actual resolved_expected
  actual="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path")"
  resolved_expected="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$expected")"
  if [ "$actual" != "$resolved_expected" ]; then
    echo "unexpected symlink target for $path: expected $resolved_expected, got $actual" >&2
    exit 1
  fi
}

assert_runtime_layout() {
  local runtime_root="$1"
  assert_file "$runtime_root/RunAtCli.lean"
  assert_file "$runtime_root/RunAtCli/Broker/Server.lean"
  assert_file "$runtime_root/RunAt/Internal/SaveArtifacts.lean"
  assert_file "$runtime_root/.lake/build/bin/runAt-cli"
  assert_file "$runtime_root/.lake/build/bin/runAt-cli-daemon"
  assert_file "$runtime_root/.lake/build/bin/runAt-cli-client"
  assert_file "$runtime_root/.lake/build/lib/librunAt_RunAt.so"
  assert_file "$runtime_root/bin/runat"
  assert_file "$runtime_root/bin/runat-lean-search"
}

assert_bundle_layout() {
  local bundle_root="$1"
  local metadata
  metadata="$(find "$bundle_root" -name metadata.json | head -n 1 || true)"
  if [ -z "$metadata" ]; then
    echo "missing bundle metadata under $bundle_root" >&2
    exit 1
  fi
  if ! rg -n --fixed-strings "\"toolchain\": \"$toolchain\"" "$metadata" > /dev/null; then
    echo "bundle metadata does not mention expected toolchain $toolchain: $metadata" >&2
    exit 1
  fi

  local workspace
  workspace="$(dirname "$metadata")/workspace"
  assert_file "$workspace/RunAtCli.lean"
  assert_file "$workspace/RunAtCli/Broker/Server.lean"
  assert_file "$workspace/RunAt/Internal/SaveArtifacts.lean"
  assert_file "$workspace/.lake/build/bin/runAt-cli-daemon"
  assert_file "$workspace/.lake/build/bin/runAt-cli-client"
  assert_file "$workspace/.lake/build/lib/librunAt_RunAt.so"
}

rsync -a --exclude='.git/' ./ "$source_checkout"/
(
  cd "$source_checkout"
  bash scripts/install-runat-skills.sh > /dev/null
)

installed_runat="$HOME/.local/bin/runat"
installed_helper="$HOME/.local/bin/runat-lean-search"
installed_runtime_root="$RUNAT_INSTALL_ROOT/current"

if [ ! -L "$installed_runat" ]; then
  echo "expected installed runat symlink at $installed_runat" >&2
  exit 1
fi

if [ ! -L "$installed_helper" ]; then
  echo "expected installed runat-lean-search symlink at $installed_helper" >&2
  exit 1
fi

assert_symlink_target "$installed_runat" "$installed_runtime_root/bin/runat"
assert_symlink_target "$installed_helper" "$installed_runtime_root/bin/runat-lean-search"
assert_runtime_layout "$installed_runtime_root"

for skills_home in "$CODEX_HOME" "$CLAUDE_HOME"; do
  assert_file "$skills_home/skills/lean-runat/SKILL.md"
  assert_file "$skills_home/skills/rocq-runat/SKILL.md"
  assert_no_skill_socket_guidance "$skills_home/skills/lean-runat/SKILL.md"
  assert_no_skill_socket_guidance "$skills_home/skills/rocq-runat/SKILL.md"
done
assert_bundle_layout "$RUNAT_INSTALL_ROOT/state/install-bundles"

rm -rf "$source_checkout"

project_root="$tmp_root/external-project"
rsync -a tests/save_olean_project/ "$project_root"/

doctor_out="$("$installed_runat" --root "$project_root" doctor lean)"
if ! printf '%s\n' "$doctor_out" | grep -q 'bundle source: installed'; then
  echo "expected installed wrapper doctor lean to resolve the installed bundle" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$doctor_out" | grep -q 'bundle ready: true'; then
  echo "expected installed wrapper doctor lean to report bundle ready" >&2
  printf '%s\n' "$doctor_out" >&2
  exit 1
fi

(
  cd "$project_root"
  lake build SaveSmoke/A.lean > /dev/null
  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
)

stale_sync_err="$(mktemp "$tmp_root/install-stale-sync-XXXXXX")"
if "$installed_runat" --root "$project_root" lean-sync SaveSmoke/A.lean >"$stale_sync_err" 2>&1; then
  echo "expected installed wrapper lean-sync to fail on a stale imported target" >&2
  cat "$stale_sync_err" >&2
  rm -f "$stale_sync_err"
  exit 1
fi
if ! grep -q '"code": "syncBarrierIncomplete"' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import lean-sync failure to expose syncBarrierIncomplete" >&2
  cat "$stale_sync_err" >&2
  rm -f "$stale_sync_err"
  exit 1
fi
if ! grep -q 'Run `lake build` or fix the upstream module first' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import lean-sync failure to include a recovery hint" >&2
  cat "$stale_sync_err" >&2
  rm -f "$stale_sync_err"
  exit 1
fi
rm -f "$stale_sync_err"

project_root_standalone="$tmp_root/external-project-standalone"
rsync -a tests/save_olean_project/ "$project_root_standalone"/

cat > "$project_root_standalone/StandaloneSaveSmoke.lean" <<'EOF'
import SaveSmoke.B

#check bVal
EOF

standalone_sync="$("$installed_runat" --root "$project_root_standalone" lean-sync StandaloneSaveSmoke.lean)"
if ! printf '%s\n' "$standalone_sync" | python3 -c 'import json,sys; payload=json.load(sys.stdin); sys.exit(0 if payload.get("error") is None else 1)'; then
  echo "expected installed wrapper lean-sync to succeed on a standalone file the daemon can open" >&2
  printf '%s\n' "$standalone_sync" >&2
  exit 1
fi

standalone_save_err="$(mktemp "$tmp_root/install-standalone-save-XXXXXX")"
if "$installed_runat" --root "$project_root_standalone" lean-save StandaloneSaveSmoke.lean >"$standalone_save_err" 2>&1; then
  echo "expected installed wrapper lean-save to reject a standalone file outside the Lake module graph" >&2
  cat "$standalone_save_err" >&2
  rm -f "$standalone_save_err"
  exit 1
fi
if ! grep -q '"code": "saveTargetNotModule"' "$standalone_save_err"; then
  echo "expected installed wrapper standalone lean-save failure to expose saveTargetNotModule" >&2
  cat "$standalone_save_err" >&2
  rm -f "$standalone_save_err"
  exit 1
fi
if ! grep -q 'lean-save only works for synced files that belong to the current Lake workspace package graph' "$standalone_save_err"; then
  echo "expected installed wrapper standalone lean-save failure to explain the Lake module requirement" >&2
  cat "$standalone_save_err" >&2
  rm -f "$standalone_save_err"
  exit 1
fi
rm -f "$standalone_save_err"
