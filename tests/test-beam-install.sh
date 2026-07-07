#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/shared-lib.sh
# shellcheck source=tests/lib/assertions.sh
. tests/lib/assertions.sh
# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh
# shellcheck source=tests/lib/install-fixtures.sh
. tests/lib/install-fixtures.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-install}"
BEAM_INSTALL_TEST_PRESEED_ELAN="${BEAM_INSTALL_TEST_PRESEED_ELAN:-auto}"

tmp_root="$(mktemp -d /tmp/beam-install-XXXXXX)"
host_elan_home="${ELAN_HOME:-}"
if [ -z "$host_elan_home" ] && [ -d "$HOME/.elan" ]; then
  host_elan_home="$HOME/.elan"
fi

cleanup() {
  expect_owned_tmp_dir "$tmp_root"
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

export HOME="$tmp_root/home"
export CODEX_HOME="$tmp_root/codex"
export CLAUDE_HOME="$tmp_root/claude"
export PI_CODING_AGENT_DIR="$tmp_root/pi-agent"
export OPENCODE_CONFIG_DIR="$tmp_root/opencode"
export BEAM_INSTALL_ROOT="$tmp_root/install-root"

mkdir -p "$HOME" "$BEAM_INSTALL_ROOT"

supported_toolchains=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  supported_toolchains+=("$line")
done < <(grep -v '^[[:space:]]*#' supported-lean-toolchains | sed '/^[[:space:]]*$/d')
toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"
if [ -z "$toolchain" ]; then
  echo "missing pinned Lean toolchain in lean-toolchain" >&2
  exit 1
fi
if ! printf '%s\n' ${supported_toolchains[@]+"${supported_toolchains[@]}"} | grep -qxF "$toolchain"; then
  echo "pinned Lean toolchain is not in supported-lean-toolchains: $toolchain" >&2
  exit 1
fi
source_checkout="$tmp_root/source-checkout"
beam_lsp_plugin_shared_lib="$(beam_shared_lib_name beam_Beam_LSP)"

assert_doctor_contains() {
  local label="$1"
  local output="$2"
  local expected="$3"
  assert_output_contains "$label doctor output" "$output" "$expected"
}

assert_doctor_not_contains() {
  local label="$1"
  local output="$2"
  local unexpected="$3"
  assert_output_not_contains "$label doctor output" "$output" "$unexpected"
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
  assert_file "$runtime_root/Beam.lean"
  assert_file "$runtime_root/Beam/Broker/Server.lean"
  assert_file "$runtime_root/Beam/LSP/Save.lean"
  assert_file "$runtime_root/Beam/LSP/DiagnosticsBarrier.lean"
  assert_file "$runtime_root/supported-lean-toolchains"
  assert_file "$runtime_root/custom-lean-toolchains"
  assert_file "$runtime_root/libexec/beam-cli"
  assert_file "$runtime_root/libexec/beam-daemon"
  assert_file "$runtime_root/libexec/beam-client"
  assert_file "$runtime_root/libexec/lean-beam-mcp"
  assert_file "$runtime_root/libexec/$beam_lsp_plugin_shared_lib"
  assert_not_exists "$runtime_root/.lake/build"
  assert_file "$runtime_root/bin/lean-beam"
  assert_file "$runtime_root/bin/lean-beam-search"
  assert_file "$runtime_root/bin/lean-beam-mcp"
  assert_not_exists "$runtime_root/bin/beam"
  assert_not_exists "$runtime_root/bin/beam-lean-search"
}

assert_manifest_metadata() {
  local manifest_path="$1"
  local expected_payload="$2"
  local expected_source_commit="$3"
  shift 3
  python3 - "$manifest_path" "$expected_payload" "$expected_source_commit" "$@" <<'PY'
import json
import os
import sys

manifest_path, expected_payload, expected_source_commit, *expected_toolchains = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)
layout = json.loads(os.environ["BEAM_INSTALL_LAYOUT_JSON"])

if manifest.get("schemaVersion") != 2:
    raise SystemExit(f"unexpected manifest schemaVersion: {manifest.get('schemaVersion')}")
if manifest.get("payloadHash") != expected_payload:
    raise SystemExit(f"unexpected manifest payloadHash: {manifest.get('payloadHash')}")
if manifest.get("toolchains") != expected_toolchains:
    raise SystemExit(f"unexpected manifest toolchains: {manifest.get('toolchains')}")
if "toolchain" in manifest:
    raise SystemExit(f"unexpected obsolete manifest toolchain field: {manifest.get('toolchain')}")
actual_source_commit = manifest.get("sourceCommit", None)
if expected_source_commit:
    if actual_source_commit != expected_source_commit:
        raise SystemExit(f"unexpected manifest sourceCommit: {actual_source_commit}")
else:
    if actual_source_commit is not None:
        raise SystemExit(f"expected manifest sourceCommit to be null or absent in non-git install copy: {actual_source_commit}")

artifacts = manifest.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("manifest artifacts payload is missing")

root_files = artifacts.get("rootFiles")
source_dirs = artifacts.get("sourceDirs")
runtime_paths = artifacts.get("runtimePaths")
wrapper_paths = artifacts.get("wrapperPaths")

expected_root_files = set(layout.get("rootFiles") or [])
expected_source_dirs = set(layout.get("sourceDirs") or [])
expected_runtime_paths = set(layout.get("runtimePaths") or [])
expected_wrapper_paths = set(layout.get("wrapperPaths") or [])

if set(root_files or []) != expected_root_files:
    raise SystemExit(f"unexpected manifest rootFiles: {root_files}")
if set(source_dirs or []) != expected_source_dirs:
    raise SystemExit(f"unexpected manifest sourceDirs: {source_dirs}")
if set(runtime_paths or []) != expected_runtime_paths:
    raise SystemExit(f"unexpected manifest runtimePaths: {runtime_paths}")
if set(wrapper_paths or []) != expected_wrapper_paths:
    raise SystemExit(f"unexpected manifest wrapperPaths: {wrapper_paths}")
PY
}

assert_version_count() {
  local versions_root="$1"
  local expected="$2"
  local actual
  if [ -d "$versions_root" ]; then
    actual="$(find "$versions_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  else
    actual="0"
  fi
  if [ "$actual" != "$expected" ]; then
    echo "expected $expected installed runtime version(s) under $versions_root, got $actual" >&2
    exit 1
  fi
}

path_without_elan() {
  local old_ifs="$IFS"
  local dir=""
  local filtered=()
  IFS=':'
  for dir in $PATH; do
    [ -n "$dir" ] || dir="."
    if [ -x "$dir/elan" ]; then
      continue
    fi
    filtered+=("$dir")
  done
  IFS="$old_ifs"
  (
    IFS=':'
    printf '%s' "${filtered[*]}"
  )
}

assert_bundle_layout() {
  local bundle_root="$1"
  shift
  local metadata_files=()
  local metadata=""
  local expected_toolchain=""
  local found=""
  while IFS= read -r metadata; do
    [ -n "$metadata" ] || continue
    metadata_files+=("$metadata")
  done < <(find "$bundle_root" -name metadata.json | sort)
  if [ "${#metadata_files[@]}" -eq 0 ]; then
    echo "missing bundle metadata under $bundle_root" >&2
    exit 1
  fi
  for expected_toolchain in "$@"; do
    found=""
    for metadata in ${metadata_files[@]+"${metadata_files[@]}"}; do
      if grep -F "\"toolchain\": \"$expected_toolchain\"" "$metadata" > /dev/null; then
        found="$metadata"
        break
      fi
    done
    if [ -z "$found" ]; then
      echo "bundle metadata does not mention expected toolchain $expected_toolchain under $bundle_root" >&2
      exit 1
    fi
    if ! grep -F '"schemaVersion": 2' "$found" > /dev/null; then
      echo "bundle metadata does not include schemaVersion 2 in $found" >&2
      exit 1
    fi
    if ! grep -F '"toolchainFingerprint"' "$found" > /dev/null; then
      echo "bundle metadata does not include toolchainFingerprint in $found" >&2
      exit 1
    fi
    local workspace
    workspace="$(dirname "$found")/workspace"
    assert_file "$workspace/.lean-beam-bundle-workspace"
    assert_file "$workspace/Beam.lean"
    assert_file "$workspace/Beam/Broker/Server.lean"
    assert_file "$workspace/Beam/LSP/Save.lean"
    assert_file "$workspace/Beam/LSP/DiagnosticsBarrier.lean"
    assert_file "$workspace/.lake/build/bin/beam-daemon"
    assert_file "$workspace/.lake/build/bin/beam-client"
    assert_file "$workspace/.lake/build/lib/$beam_lsp_plugin_shared_lib"
  done
}

run_install_from_source() {
  preseed_elan_home "$HOME/.elan" ${supported_toolchains[@]+"${supported_toolchains[@]}"}
  (
    cd "$source_checkout"
    bash scripts/install-beam.sh --dont-ask "$@" > /dev/null
  )
}

rsync -a --exclude='.git' ./ "$source_checkout"/
path_no_elan="$(path_without_elan)"
if PATH="$path_no_elan" command -v elan >/dev/null 2>&1; then
  echo "failed to construct a PATH without elan for the negative install test" >&2
  exit 1
fi
missing_elan_err="$(mktemp "$tmp_root/install-missing-elan-XXXXXX")"
if (
  cd "$source_checkout"
  PATH="$path_no_elan" bash scripts/install-beam.sh > /dev/null 2>"$missing_elan_err"
); then
  echo "expected install to fail when elan is missing from PATH" >&2
  cat "$missing_elan_err" >&2
  remove_tmp_file "$missing_elan_err"
  exit 1
fi
if ! grep -q 'missing elan on PATH' "$missing_elan_err"; then
  echo "expected missing-elan install failure to explain the prebuild requirement" >&2
  cat "$missing_elan_err" >&2
  remove_tmp_file "$missing_elan_err"
  exit 1
fi
remove_tmp_file "$missing_elan_err"
assert_not_exists "$HOME/.local"
assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_not_exists "$PI_CODING_AGENT_DIR"
assert_not_exists "$OPENCODE_CONFIG_DIR"
assert_not_exists "$BEAM_INSTALL_ROOT/current"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 0
assert_not_exists "$BEAM_INSTALL_ROOT/state"

relative_root_err="$(mktemp "$tmp_root/install-relative-root-XXXXXX")"
if (
  cd "$source_checkout"
  BEAM_INSTALL_ROOT="relative/install-root" bash scripts/install-beam.sh > /dev/null 2>"$relative_root_err"
); then
  echo "expected install to fail when BEAM_INSTALL_ROOT is relative" >&2
  cat "$relative_root_err" >&2
  remove_tmp_file "$relative_root_err"
  exit 1
fi
if ! grep -q 'install root must be an absolute path' "$relative_root_err"; then
  echo "expected relative install root failure to explain the absolute-path requirement" >&2
  cat "$relative_root_err" >&2
  remove_tmp_file "$relative_root_err"
  exit 1
fi
remove_tmp_file "$relative_root_err"
assert_not_exists "$source_checkout/relative"

unsupported_install_err="$(mktemp "$tmp_root/install-unsupported-toolchain-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --toolchain leanprover/lean4:v4.26.0 > /dev/null 2>"$unsupported_install_err"
); then
  echo "expected install to fail when an unsupported toolchain is requested explicitly" >&2
  cat "$unsupported_install_err" >&2
  remove_tmp_file "$unsupported_install_err"
  exit 1
fi
if ! grep -q 'unsupported Lean toolchain requested for install: leanprover/lean4:v4.26.0' "$unsupported_install_err"; then
  echo "expected unsupported installer toolchain failure to name the rejected toolchain" >&2
  cat "$unsupported_install_err" >&2
  remove_tmp_file "$unsupported_install_err"
  exit 1
fi
remove_tmp_file "$unsupported_install_err"
assert_not_exists "$BEAM_INSTALL_ROOT/current"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 0
assert_not_exists "$BEAM_INSTALL_ROOT/state"

no_prompt_home="$tmp_root/no-prompt-home"
no_prompt_install_root="$tmp_root/no-prompt-install-root"
mkdir -p "$no_prompt_home"
no_prompt_err="$(mktemp "$tmp_root/install-no-prompt-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$no_prompt_home" BEAM_INSTALL_ROOT="$no_prompt_install_root" \
    bash scripts/install-beam.sh > /dev/null 2>"$no_prompt_err"
); then
  echo "expected install to fail non-interactively without --dont-ask" >&2
  cat "$no_prompt_err" >&2
  remove_tmp_file "$no_prompt_err"
  exit 1
fi
assert_contains "$no_prompt_err" 'without confirmation'
remove_tmp_file "$no_prompt_err"
assert_not_exists "$no_prompt_home/.local"
assert_not_exists "$no_prompt_install_root"

invalid_approval_home="$tmp_root/invalid-approval-home"
invalid_approval_install_root="$tmp_root/invalid-approval-install-root"
invalid_approval_transcript="$tmp_root/install-invalid-approval-transcript"
mkdir -p "$invalid_approval_home"
if beam_install_run_interactive_from_source \
    "$invalid_approval_transcript" "$invalid_approval_home" "$invalid_approval_install_root" \
    $'\n\n\nmaybe\n'; then
  echo "expected interactive install to reject an unknown write approval response" >&2
  cat "$invalid_approval_transcript" >&2
  exit 1
fi
assert_contains "$invalid_approval_transcript" 'Write Locations'
assert_contains "$invalid_approval_transcript" 'Allow lean-beam to write to these locations?'
assert_contains "$invalid_approval_transcript" 'unknown write-permission response: maybe'
assert_not_exists "$invalid_approval_install_root"
remove_tmp_file "$invalid_approval_transcript"

change_alias_home="$tmp_root/change-alias-home"
change_alias_install_root="$tmp_root/change-alias-install-root"
change_alias_transcript="$tmp_root/install-change-alias-transcript"
mkdir -p "$change_alias_home"
if beam_install_run_interactive_from_source \
    "$change_alias_transcript" "$change_alias_home" "$change_alias_install_root" \
    $'\n\n\nc\n\n\nN\n'; then
  echo "expected interactive install to stop after change alias then denied write permission" >&2
  cat "$change_alias_transcript" >&2
  exit 1
fi
assert_contains "$change_alias_transcript" 'Write Locations'
assert_contains "$change_alias_transcript" 'Change Locations'
assert_contains_literal "$change_alias_transcript" "Command directory [$change_alias_home/.local/bin]"
assert_contains_literal "$change_alias_transcript" "Runtime install root [$change_alias_install_root]"
assert_contains_literal "$change_alias_transcript" "Command directory: $change_alias_home/.local/bin"
assert_contains_literal "$change_alias_transcript" "Runtime root: $change_alias_install_root"
assert_contains "$change_alias_transcript" 'cancelled before: Write Locations'
assert_not_exists "$change_alias_install_root"
remove_tmp_file "$change_alias_transcript"

interactive_home="$tmp_root/interactive-home"
interactive_install_root="$tmp_root/interactive-install-root"
interactive_transcript="$tmp_root/install-interactive-transcript"
mkdir -p "$interactive_home"
if ! beam_install_run_interactive_from_source "$interactive_transcript" "$interactive_home" "$interactive_install_root" $'\n\n\nY\n'; then
  echo "expected interactive default install to succeed" >&2
  cat "$interactive_transcript" >&2
  exit 1
fi
assert_contains "$interactive_transcript" 'Prebuild toolchains'
assert_contains "$interactive_transcript" 'Lean agent skill targets to install'
assert_contains "$interactive_transcript" 'MCP clients'
assert_contains "$interactive_transcript" 'commands'
assert_contains "$interactive_transcript" 'Write Locations'
assert_contains "$interactive_transcript" 'Lean Beam will create or update the following locations:'
assert_contains "$interactive_transcript" 'Command directory'
assert_contains "$interactive_transcript" 'Runtime root'
assert_contains "$interactive_transcript" 'Bundle cache'
assert_contains "$interactive_transcript" 'Source build output'
assert_contains "$interactive_transcript" 'Allow lean-beam to write to these locations?'
assert_contains "$interactive_transcript" 'building beam runtime artifacts'
assert_contains "$interactive_transcript" 'MCP restart'
assert_not_contains "$interactive_transcript" 'Allow this edit?'
assert_file "$interactive_install_root/.lean-beam-install-root"
assert_file "$interactive_home/.local/bin/lean-beam"
assert_not_exists "$interactive_home/.codex"
assert_not_exists "$interactive_home/.claude"
assert_not_exists "$interactive_home/.pi"
assert_not_exists "$interactive_home/.config/opencode"
remove_tmp_file "$interactive_transcript"

interactive_claude_home="$tmp_root/interactive-claude-home"
interactive_claude_install_root="$tmp_root/interactive-claude-install-root"
interactive_claude_config_home="$tmp_root/interactive-claude-sandbox"
interactive_claude_config="$interactive_claude_config_home/.claude.json"
interactive_claude_transcript="$tmp_root/install-interactive-claude-transcript"
interactive_mcp_stub_bin="$tmp_root/interactive-mcp-stubs"
interactive_mcp_stub_log="$tmp_root/interactive-mcp-stubs.log"
mkdir -p "$interactive_claude_home"
beam_install_setup_mcp_cli_stubs "$interactive_mcp_stub_bin" "$interactive_mcp_stub_log"
if BEAM_TEST_MCP_STUB_LOG="$interactive_mcp_stub_log" PATH="$interactive_mcp_stub_bin:$PATH" \
    beam_install_run_interactive_from_source \
      "$interactive_claude_transcript" "$interactive_claude_home" "$interactive_claude_install_root" \
      $'\n\n3\nchange\n\n\n'"$interactive_claude_config"$'\nN\n'; then
  echo "expected interactive Claude MCP install to stop when write permission is denied" >&2
  cat "$interactive_claude_transcript" >&2
  exit 1
fi
assert_contains "$interactive_claude_transcript" 'Write Locations'
assert_contains "$interactive_claude_transcript" 'Change Locations'
assert_contains "$interactive_claude_transcript" 'Command directory'
assert_contains "$interactive_claude_transcript" 'Runtime install root'
assert_contains_literal "$interactive_claude_transcript" \
  "Claude Code user config [$interactive_claude_home/.claude.json]"
assert_contains_literal "$interactive_claude_transcript" "$interactive_claude_config"
assert_contains_literal "$interactive_claude_transcript" "Claude Code config: $interactive_claude_config"
assert_contains "$interactive_claude_transcript" 'Allow lean-beam to write to these locations?'
assert_contains "$interactive_claude_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_claude_install_root"
assert_not_exists "$interactive_claude_home/.claude.json"
remove_tmp_file "$interactive_claude_transcript"

interactive_codex_home="$tmp_root/interactive-codex-home"
interactive_codex_install_root="$tmp_root/interactive-codex-install-root"
interactive_codex_custom_home="$tmp_root/interactive-codex-sandbox"
interactive_codex_custom_bin="$tmp_root/interactive-codex-bin"
interactive_codex_custom_runtime="$tmp_root/interactive-codex-runtime"
interactive_codex_transcript="$tmp_root/install-interactive-codex-transcript"
mkdir -p "$interactive_codex_home"
if beam_install_run_interactive_from_source \
    "$interactive_codex_transcript" "$interactive_codex_home" "$interactive_codex_install_root" \
    $'\n\n2\nchange\n'"$interactive_codex_custom_bin"$'\n'"$interactive_codex_custom_runtime"$'\n'"$interactive_codex_custom_home"$'\nN\n'; then
  echo "expected interactive Codex MCP install to stop when write permission is denied" >&2
  cat "$interactive_codex_transcript" >&2
  exit 1
fi
assert_contains "$interactive_codex_transcript" 'Write Locations'
assert_contains "$interactive_codex_transcript" 'Change Locations'
assert_contains_literal "$interactive_codex_transcript" "Command directory [$interactive_codex_home/.local/bin]"
assert_contains_literal "$interactive_codex_transcript" "Runtime install root [$interactive_codex_install_root]"
assert_contains_literal "$interactive_codex_transcript" "Codex home [$CODEX_HOME]"
assert_contains_literal "$interactive_codex_transcript" "Command directory: $interactive_codex_custom_bin"
assert_contains_literal "$interactive_codex_transcript" "Runtime root: $interactive_codex_custom_runtime"
assert_contains_literal "$interactive_codex_transcript" "Codex home: $interactive_codex_custom_home"
assert_contains_literal "$interactive_codex_transcript" "Codex config: $interactive_codex_custom_home/config.toml"
assert_contains "$interactive_codex_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_codex_custom_bin"
assert_not_exists "$interactive_codex_custom_runtime"
assert_not_exists "$interactive_codex_custom_home"
remove_tmp_file "$interactive_codex_transcript"

interactive_opencode_home="$tmp_root/interactive-opencode-home"
interactive_opencode_install_root="$tmp_root/interactive-opencode-install-root"
interactive_opencode_custom_bin="$tmp_root/interactive-opencode-bin"
interactive_opencode_custom_runtime="$tmp_root/interactive-opencode-runtime"
interactive_opencode_transcript="$tmp_root/install-interactive-opencode-transcript"
mkdir -p "$interactive_opencode_home"
if beam_install_run_interactive_from_source \
    "$interactive_opencode_transcript" "$interactive_opencode_home" "$interactive_opencode_install_root" \
    $'\n\n4\nchange\n'"$interactive_opencode_custom_bin"$'\n'"$interactive_opencode_custom_runtime"$'\nN\n'; then
  echo "expected interactive OpenCode MCP install to stop when write permission is denied" >&2
  cat "$interactive_opencode_transcript" >&2
  exit 1
fi
assert_contains "$interactive_opencode_transcript" 'Write Locations'
assert_contains "$interactive_opencode_transcript" 'Change Locations'
assert_contains_literal "$interactive_opencode_transcript" "Command directory [$interactive_opencode_home/.local/bin]"
assert_contains_literal "$interactive_opencode_transcript" "Runtime install root [$interactive_opencode_install_root]"
assert_contains_literal "$interactive_opencode_transcript" "Command directory: $interactive_opencode_custom_bin"
assert_contains_literal "$interactive_opencode_transcript" "Runtime root: $interactive_opencode_custom_runtime"
assert_contains "$interactive_opencode_transcript" 'Manual follow-up'
assert_contains_literal "$interactive_opencode_transcript" 'OpenCode MCP registration requires manual steps after install.'
assert_not_contains "$interactive_opencode_transcript" 'Run after install: opencode mcp add'
assert_not_contains "$interactive_opencode_transcript" 'MCP command:'
assert_contains "$interactive_opencode_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_opencode_custom_bin"
assert_not_exists "$interactive_opencode_custom_runtime"
remove_tmp_file "$interactive_opencode_transcript"

run_step "install default runtime" run_install_from_source
expected_source_commit="$(git -C "$source_checkout" rev-parse HEAD 2>/dev/null || true)"
install_layout_json="$(cd "$source_checkout" && ./.lake/build/bin/beam-cli install-layout)"

installed_lean_beam="$HOME/.local/bin/lean-beam"
installed_helper="$HOME/.local/bin/lean-beam-search"
installed_mcp="$HOME/.local/bin/lean-beam-mcp"
installed_runtime_root="$BEAM_INSTALL_ROOT/current"

if [ ! -L "$installed_lean_beam" ]; then
  echo "expected installed lean-beam symlink at $installed_lean_beam" >&2
  exit 1
fi

if [ ! -L "$installed_helper" ]; then
  echo "expected installed lean-beam-search symlink at $installed_helper" >&2
  exit 1
fi

if [ ! -L "$installed_mcp" ]; then
  echo "expected installed lean-beam-mcp symlink at $installed_mcp" >&2
  exit 1
fi

assert_symlink_target "$installed_lean_beam" "$installed_runtime_root/bin/lean-beam"
assert_symlink_target "$installed_helper" "$installed_runtime_root/bin/lean-beam-search"
assert_symlink_target "$installed_mcp" "$installed_runtime_root/bin/lean-beam-mcp"
assert_not_exists "$HOME/.local/bin/beam"
assert_not_exists "$HOME/.local/bin/beam-lean-search"
assert_runtime_layout "$installed_runtime_root"
assert_file "$BEAM_INSTALL_ROOT/.lean-beam-install-root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
installed_version_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$installed_runtime_root")"
installed_payload_id="$(basename "$installed_version_root")"
assert_file "$installed_runtime_root/manifest.json"
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"
installed_lean_beam_version="$("$installed_lean_beam" --version)"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "lean-beam 0.1.0"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "wrapper: $installed_version_root/bin/lean-beam"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "beam home: $installed_version_root"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "beam cli: $installed_version_root/libexec/beam-cli"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "runtime payload: $installed_payload_id"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "manifest: $installed_version_root/manifest.json"
if [ -n "$expected_source_commit" ]; then
  assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "source commit: $expected_source_commit"
fi
installed_mcp_version="$("$installed_mcp" --version)"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "lean-beam-mcp 0.1.0"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "mcp protocol: 2025-11-25"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "wrapper: $installed_version_root/bin/lean-beam-mcp"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "server binary: $installed_version_root/libexec/lean-beam-mcp"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "beam cli: $installed_version_root/libexec/beam-cli"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "runtime payload: $installed_payload_id"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "manifest: $installed_version_root/manifest.json"
if [ -n "$expected_source_commit" ]; then
  assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "source commit: $expected_source_commit"
fi

assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_not_exists "$PI_CODING_AGENT_DIR"
assert_not_exists "$OPENCODE_CONFIG_DIR"
assert_bundle_layout "$BEAM_INSTALL_ROOT/state/install-bundles" "$toolchain"

blocked_bundle_root="$tmp_root/blocked-bundles"
BEAM_HOME="$installed_runtime_root" BEAM_INSTALL_BUNDLE_DIR="$blocked_bundle_root" \
  "$installed_runtime_root/libexec/beam-cli" bundle-install "$toolchain" > /dev/null
blocked_bundle_metadata="$(find "$blocked_bundle_root" -name metadata.json | sort | head -n 1)"
if [ -z "$blocked_bundle_metadata" ]; then
  echo "expected blocked bundle setup to create metadata" >&2
  exit 1
fi
blocked_bundle_workspace="$(dirname "$blocked_bundle_metadata")/workspace"
printf 'sentinel\n' >"$blocked_bundle_workspace/user-file.txt"
remove_tmp_file "$blocked_bundle_workspace/.lean-beam-bundle-workspace"
remove_tmp_file "$blocked_bundle_workspace/.lake/build/bin/beam-client"
blocked_bundle_err="$(mktemp "$tmp_root/bundle-unmarked-workspace-XXXXXX")"
if BEAM_HOME="$installed_runtime_root" BEAM_INSTALL_BUNDLE_DIR="$blocked_bundle_root" \
  "$installed_runtime_root/libexec/beam-cli" bundle-install "$toolchain" > /dev/null 2>"$blocked_bundle_err"; then
  echo "expected bundle rebuild to fail for an unmarked existing workspace" >&2
  cat "$blocked_bundle_err" >&2
  remove_tmp_file "$blocked_bundle_err"
  exit 1
fi
assert_contains "$blocked_bundle_err" 'refusing to remove unmarked existing bundle workspace'
remove_tmp_file "$blocked_bundle_err"
assert_file "$blocked_bundle_workspace/user-file.txt"

run_custom_toolchain_install_test() (
  set -e

  local custom_toolchain="beam-test-custom"
  local custom_elan_home="$tmp_root/custom-elan"
  local custom_install_home="$tmp_root/custom-home"
  local custom_install_root="$tmp_root/custom-install-root"
  local host_lean_path=""
  local custom_toolchain_dir=""
  local custom_installed_lean_beam=""
  local custom_installed_runtime_root=""
  local custom_installed_version_root=""
  local custom_installed_payload_id=""
  local custom_project_root=""
  local custom_doctor_out=""

  mkdir -p "$custom_elan_home" "$custom_install_home" "$custom_install_root"
  preseed_elan_home "$custom_elan_home" "$toolchain"
  if [ -n "$host_elan_home" ]; then
    host_lean_path="$(ELAN_HOME="$host_elan_home" elan which lean)"
  else
    host_lean_path="$(elan which lean)"
  fi
  custom_toolchain_dir="$(dirname "$(dirname "$host_lean_path")")"
  ELAN_HOME="$custom_elan_home" elan toolchain link "$custom_toolchain" "$custom_toolchain_dir" > /dev/null
  (
    cd "$source_checkout"
    HOME="$custom_install_home" BEAM_INSTALL_ROOT="$custom_install_root" ELAN_HOME="$custom_elan_home" \
      bash scripts/install-beam.sh --dont-ask --custom-toolchain "$custom_toolchain" > /dev/null
  )
  custom_installed_lean_beam="$custom_install_home/.local/bin/lean-beam"
  custom_installed_runtime_root="$custom_install_root/current"
  assert_runtime_layout "$custom_installed_runtime_root"
  assert_contains_literal "$custom_installed_runtime_root/custom-lean-toolchains" "$custom_toolchain"
  assert_version_count "$custom_install_root/versions" 1
  custom_installed_version_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$custom_installed_runtime_root")"
  custom_installed_payload_id="$(basename "$custom_installed_version_root")"
  BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata \
    "$custom_installed_runtime_root/manifest.json" \
    "$custom_installed_payload_id" \
    "$expected_source_commit" \
    "$custom_toolchain"
  assert_bundle_layout "$custom_install_root/state/install-bundles" "$custom_toolchain"

  custom_project_root="$tmp_root/custom-project"
  rsync -a tests/save_olean_project/ "$custom_project_root"/
  printf '%s\n' "$custom_toolchain" > "$custom_project_root/lean-toolchain"
  custom_doctor_out="$(ELAN_HOME="$custom_elan_home" "$custom_installed_lean_beam" --root "$custom_project_root" doctor)"
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" 'project toolchain supported: false'
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" 'project toolchain custom: true'
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" 'project toolchain accepted: true'
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" 'bundle source: installed'
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" 'bundle toolchain fingerprint: '
  ELAN_HOME="$custom_elan_home" "$custom_installed_lean_beam" --root "$custom_project_root" ensure > /dev/null
  ELAN_HOME="$custom_elan_home" "$custom_installed_lean_beam" --root "$custom_project_root" shutdown > /dev/null
)

run_step "install custom toolchain runtime" run_custom_toolchain_install_test

release_pre_all_supported_disk() {
  remove_tmp_tree "$blocked_bundle_root"
  remove_tmp_tree "$tmp_root/custom-elan"
  remove_tmp_tree "$tmp_root/custom-home"
  remove_tmp_tree "$tmp_root/custom-install-root"
  remove_tmp_tree "$tmp_root/custom-project"
}

run_step "release install temp trees before all-supported" release_pre_all_supported_disk

run_step "prebuild all supported bundles" run_install_from_source --all-supported

assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"
assert_bundle_layout "$BEAM_INSTALL_ROOT/state/install-bundles" ${supported_toolchains[@]+"${supported_toolchains[@]}"}

rocq_no_target_err="$(mktemp "$tmp_root/rocq-skill-no-target-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --rocq-skill > /dev/null 2>"$rocq_no_target_err"
); then
  echo "expected --rocq-skill without an agent target to fail" >&2
  remove_tmp_file "$rocq_no_target_err"
  exit 1
fi
assert_contains "$rocq_no_target_err" "rocq-skill requires"
remove_tmp_file "$rocq_no_target_err"
assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_not_exists "$PI_CODING_AGENT_DIR"
assert_not_exists "$OPENCODE_CONFIG_DIR"

run_step "install Lean skills" run_install_from_source --toolchain "$toolchain" --all-skills

for skills_home in "$CODEX_HOME/skills" "$CLAUDE_HOME/skills" "$PI_CODING_AGENT_DIR/skills" "$OPENCODE_CONFIG_DIR/skills"; do
  assert_file "$skills_home/lean-beam/SKILL.md"
  assert_file "$skills_home/lean-beam/.lean-beam-skill"
  assert_not_exists "$skills_home/rocq-beam"
done
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"

run_step "install optional Rocq skills" run_install_from_source --toolchain "$toolchain" --all-skills --rocq-skill

for skills_home in "$CODEX_HOME/skills" "$CLAUDE_HOME/skills" "$PI_CODING_AGENT_DIR/skills" "$OPENCODE_CONFIG_DIR/skills"; do
  assert_file "$skills_home/lean-beam/SKILL.md"
  assert_file "$skills_home/lean-beam/.lean-beam-skill"
  assert_file "$skills_home/rocq-beam/SKILL.md"
  assert_file "$skills_home/rocq-beam/.lean-beam-skill"
done
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"

codex_only_home="$tmp_root/codex-only-codex"
claude_only_home="$tmp_root/codex-only-claude"
run_step "install optional Rocq skill for Codex only" \
  env CODEX_HOME="$codex_only_home" CLAUDE_HOME="$claude_only_home" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" --codex --rocq-skill
assert_file "$codex_only_home/skills/lean-beam/SKILL.md"
assert_file "$codex_only_home/skills/rocq-beam/SKILL.md"
assert_not_exists "$claude_only_home"

mcp_stub_bin="$tmp_root/mcp-stubs"
mcp_stub_log="$tmp_root/mcp-stubs.log"
beam_install_setup_mcp_cli_stubs "$mcp_stub_bin" "$mcp_stub_log"
run_step "register MCP clients" beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$mcp_stub_log" --toolchain "$toolchain" --all-mcp
assert_contains_literal "$mcp_stub_log" "codex|mcp|add|lean-beam|--|$installed_mcp"
assert_contains_literal "$mcp_stub_log" "claude|mcp|remove|--scope|user|lean-beam"
assert_contains_literal "$mcp_stub_log" "claude|mcp|add|--scope|user|lean-beam|--|$installed_mcp"
assert_not_exists "$OPENCODE_CONFIG_DIR/opencode.json"

custom_codex_home="$tmp_root/codex-sandbox"
custom_codex_mcp_stub_log="$tmp_root/mcp-stubs-custom-codex.log"
run_step "register Codex MCP with custom home" \
  beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$custom_codex_mcp_stub_log" \
    --toolchain "$toolchain" --codex-mcp --codex-home "$custom_codex_home"
if [ ! -d "$custom_codex_home" ]; then
  echo "expected installer to create custom Codex home" >&2
  exit 1
fi
assert_contains_literal "$custom_codex_mcp_stub_log" \
  "codex|mcp|add|lean-beam|--|$installed_mcp|CODEX_HOME=$custom_codex_home"

custom_claude_config_home="$tmp_root/claude-sandbox"
custom_claude_config="$custom_claude_config_home/.claude.json"
custom_mcp_stub_log="$tmp_root/mcp-stubs-custom-claude.log"
run_step "register Claude MCP with custom config" \
  beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$custom_mcp_stub_log" \
    --toolchain "$toolchain" --claude-mcp --claude-mcp-config "$custom_claude_config"
if [ ! -d "$custom_claude_config_home" ]; then
  echo "expected installer to create custom Claude MCP config home" >&2
  exit 1
fi
assert_contains_literal "$custom_mcp_stub_log" \
  "claude|mcp|remove|--scope|user|lean-beam|HOME=$custom_claude_config_home"
assert_contains_literal "$custom_mcp_stub_log" \
  "claude|mcp|add|--scope|user|lean-beam|--|$installed_mcp|HOME=$custom_claude_config_home"
assert_not_exists "$HOME/.claude.json"

opencode_mcp_transcript="$tmp_root/opencode-mcp-manual-transcript"
preseed_elan_home "$HOME/.elan" "$toolchain"
run_step "show OpenCode MCP setup" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" --opencode-mcp \
    >"$opencode_mcp_transcript" 2>&1
assert_contains "$opencode_mcp_transcript" 'Manual Step Required: OpenCode MCP'
assert_contains_literal "$opencode_mcp_transcript" 'run                opencode mcp add'
assert_contains_literal "$opencode_mcp_transcript" 'name               lean-beam'
assert_contains_literal "$opencode_mcp_transcript" 'type               local'
assert_contains_literal "$opencode_mcp_transcript" "command            $installed_mcp"
assert_not_exists "$OPENCODE_CONFIG_DIR/opencode.json"
remove_tmp_file "$opencode_mcp_transcript"

relative_codex_home_err="$(mktemp "$tmp_root/codex-mcp-relative-home-XXXXXX")"
if (
  cd "$source_checkout"
  BEAM_TEST_MCP_STUB_LOG="$mcp_stub_log" PATH="$mcp_stub_bin:$PATH" \
    bash scripts/install-beam.sh --dont-ask --codex-mcp \
      --codex-home relative/.codex > /dev/null 2>"$relative_codex_home_err"
); then
  echo "expected --codex-home to reject relative paths" >&2
  remove_tmp_file "$relative_codex_home_err"
  exit 1
fi
assert_contains "$relative_codex_home_err" "Codex home must be an absolute path"
remove_tmp_file "$relative_codex_home_err"

relative_claude_config_err="$(mktemp "$tmp_root/claude-mcp-relative-config-XXXXXX")"
if (
  cd "$source_checkout"
  BEAM_TEST_MCP_STUB_LOG="$mcp_stub_log" PATH="$mcp_stub_bin:$PATH" \
    bash scripts/install-beam.sh --dont-ask --claude-mcp \
      --claude-mcp-config relative/.claude.json > /dev/null 2>"$relative_claude_config_err"
); then
  echo "expected --claude-mcp-config to reject relative paths" >&2
  remove_tmp_file "$relative_claude_config_err"
  exit 1
fi
assert_contains "$relative_claude_config_err" "Claude Code MCP config must be an absolute path"
remove_tmp_file "$relative_claude_config_err"

relative_pi_home_err="$(mktemp "$tmp_root/pi-skill-relative-home-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --pi --pi-home relative/.pi/agent > /dev/null 2>"$relative_pi_home_err"
); then
  echo "expected --pi-home to reject relative paths" >&2
  remove_tmp_file "$relative_pi_home_err"
  exit 1
fi
assert_contains "$relative_pi_home_err" "Pi Agent home must be an absolute path"
remove_tmp_file "$relative_pi_home_err"

relative_opencode_config_dir_err="$(mktemp "$tmp_root/opencode-relative-config-dir-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --opencode \
    --opencode-config-dir relative/opencode > /dev/null 2>"$relative_opencode_config_dir_err"
); then
  echo "expected --opencode-config-dir to reject relative paths" >&2
  remove_tmp_file "$relative_opencode_config_dir_err"
  exit 1
fi
assert_contains "$relative_opencode_config_dir_err" "OpenCode config dir must be an absolute path"
remove_tmp_file "$relative_opencode_config_dir_err"

blocked_home="$tmp_root/blocked-home"
blocked_install_root="$tmp_root/blocked-install-root"
blocked_lean_beam_dir="$blocked_home/.local/bin/lean-beam"
mkdir -p "$blocked_lean_beam_dir" "$blocked_install_root"
blocked_wrapper_err="$(mktemp "$tmp_root/install-wrapper-dir-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_home" BEAM_INSTALL_ROOT="$blocked_install_root" \
    bash scripts/install-beam.sh --dont-ask > /dev/null 2>"$blocked_wrapper_err"
); then
  echo "expected install to fail when the wrapper target path is a real directory" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
if ! grep -q "refusing to replace directory at $blocked_lean_beam_dir" "$blocked_wrapper_err"; then
  echo "expected wrapper-directory install failure to explain the refusal" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
remove_tmp_file "$blocked_wrapper_err"
if [ ! -d "$blocked_lean_beam_dir" ]; then
  echo "expected blocked wrapper directory to remain untouched" >&2
  exit 1
fi
assert_not_exists "$blocked_home/.local/bin/lean-beam-search"
assert_not_exists "$blocked_home/.local/bin/lean-beam-mcp"
assert_not_exists "$blocked_home/.local/bin/beam"
assert_not_exists "$blocked_home/.local/bin/beam-lean-search"
assert_not_exists "$blocked_install_root/current"
assert_not_exists "$blocked_install_root/versions"
assert_not_exists "$blocked_install_root/state"

blocked_file_home="$tmp_root/blocked-file-home"
blocked_file_install_root="$tmp_root/blocked-file-install-root"
blocked_lean_beam_file="$blocked_file_home/.local/bin/lean-beam"
mkdir -p "$(dirname "$blocked_lean_beam_file")" "$blocked_file_install_root"
printf 'user file\n' >"$blocked_lean_beam_file"
blocked_file_err="$(mktemp "$tmp_root/install-wrapper-file-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_file_home" BEAM_INSTALL_ROOT="$blocked_file_install_root" \
    bash scripts/install-beam.sh --dont-ask > /dev/null 2>"$blocked_file_err"
); then
  echo "expected install to fail when the wrapper target path is a regular file" >&2
  cat "$blocked_file_err" >&2
  remove_tmp_file "$blocked_file_err"
  exit 1
fi
assert_contains "$blocked_file_err" "refusing to replace non-Beam path at $blocked_lean_beam_file"
remove_tmp_file "$blocked_file_err"
if [ "$(cat "$blocked_lean_beam_file")" != "user file" ]; then
  echo "expected blocked wrapper file to remain untouched" >&2
  exit 1
fi
assert_not_exists "$blocked_file_home/.local/bin/lean-beam-search"
assert_not_exists "$blocked_file_home/.local/bin/lean-beam-mcp"
assert_not_exists "$blocked_file_install_root/current"

blocked_skill_home="$tmp_root/blocked-skill-home"
blocked_skill_install_root="$tmp_root/blocked-skill-install-root"
blocked_codex_home="$tmp_root/blocked-codex"
mkdir -p "$blocked_skill_home" "$blocked_codex_home/skills/lean-beam"
printf 'user skill\n' >"$blocked_codex_home/skills/lean-beam/custom.txt"
blocked_skill_err="$(mktemp "$tmp_root/install-skill-dir-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_skill_home" CODEX_HOME="$blocked_codex_home" \
    CLAUDE_HOME="$tmp_root/blocked-claude" BEAM_INSTALL_ROOT="$blocked_skill_install_root" \
    bash scripts/install-beam.sh --dont-ask --codex > /dev/null 2>"$blocked_skill_err"
); then
  echo "expected install to fail when the skill target directory is unmarked" >&2
  cat "$blocked_skill_err" >&2
  remove_tmp_file "$blocked_skill_err"
  exit 1
fi
assert_contains "$blocked_skill_err" "refusing to replace unmarked existing lean-beam skill directory"
remove_tmp_file "$blocked_skill_err"
assert_file "$blocked_codex_home/skills/lean-beam/custom.txt"
assert_not_exists "$blocked_codex_home/skills/rocq-beam"

remove_tmp_tree "$source_checkout"

project_root="$tmp_root/external-project"
rsync -a tests/save_olean_project/ "$project_root"/
project_toolchain="$(awk 'NR==1 {print $1}' "$project_root/lean-toolchain")"
if [ -z "$project_toolchain" ]; then
  echo "missing Lean toolchain in external install smoke project" >&2
  exit 1
fi

supported_out="$("$installed_lean_beam" supported-toolchains)"
if ! printf '%s\n' "$supported_out" | grep -qx "$toolchain"; then
  echo "expected supported-toolchains to include the pinned repo toolchain" >&2
  printf '%s\n' "$supported_out" >&2
  exit 1
fi

doctor_out="$("$installed_lean_beam" --root "$project_root" doctor)"
assert_doctor_contains "installed wrapper" "$doctor_out" 'project toolchain supported: true'
assert_doctor_contains "installed wrapper" "$doctor_out" 'supported toolchains registry: '
assert_doctor_contains "installed wrapper" "$doctor_out" 'bundle source inputs: '
assert_doctor_contains "installed wrapper" "$doctor_out" 'bundle key inputs: toolchain, toolchain fingerprint, platform, source hash'
assert_doctor_contains "installed wrapper" "$doctor_out" 'bundle toolchain fingerprint: '
assert_doctor_contains "installed wrapper" "$doctor_out" 'supported-lean-toolchains'
assert_doctor_contains "installed wrapper" "$doctor_out" 'custom-lean-toolchains'
assert_doctor_not_contains "installed wrapper" "$doctor_out" '.lake/packages'
assert_doctor_contains "installed wrapper" "$doctor_out" 'bundle source: installed'
assert_doctor_contains "installed wrapper" "$doctor_out" 'bundle ready: true'

mcp_config_json="$(BEAM_HOME="$installed_runtime_root" "$installed_runtime_root/libexec/beam-cli" --root "$project_root" mcp-config)"
MCP_CONFIG_JSON="$mcp_config_json" EXPECTED_TOOLCHAIN="$project_toolchain" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

payload = json.loads(os.environ["MCP_CONFIG_JSON"])
expected_toolchain = os.environ["EXPECTED_TOOLCHAIN"]
lean_cmd = payload.get("lean_cmd")
lean_plugin = payload.get("lean_plugin")
if not isinstance(lean_cmd, str) or not lean_cmd:
    print(f"mcp-config did not return a lean_cmd: {payload}", file=sys.stderr)
    sys.exit(1)
if not isinstance(lean_plugin, str) or not Path(lean_plugin).is_file():
    print(f"mcp-config did not return an existing lean_plugin: {payload}", file=sys.stderr)
    sys.exit(1)
if payload.get("toolchain") != expected_toolchain:
    print(f"mcp-config returned unexpected toolchain: {payload}", file=sys.stderr)
    sys.exit(1)
if not isinstance(payload.get("bundle_id"), str) or not payload["bundle_id"]:
    print(f"mcp-config did not return a bundle_id: {payload}", file=sys.stderr)
    sys.exit(1)
PY

mcp_smoke_out="$(mktemp "$tmp_root/install-mcp-smoke-out-XXXXXX")"
mcp_smoke_err="$(mktemp "$tmp_root/install-mcp-smoke-err-XXXXXX")"
if ! python3 - "$installed_mcp" "$project_root" >"$mcp_smoke_out" 2>"$mcp_smoke_err" <<'PY'
import json
import select
import subprocess
import sys
import time

server, project_root = sys.argv[1:]
proc = subprocess.Popen(
    [server, "--root", project_root],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",
    bufsize=1,
)

def send(message):
    proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    proc.stdin.flush()

def recv(expected_id):
    deadline = time.monotonic() + 25
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f"timed out waiting for MCP response id {expected_id}")
        if proc.poll() is not None:
            raise RuntimeError(f"lean-beam-mcp exited early with {proc.returncode}: {proc.stderr.read()}")
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            continue
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError(f"lean-beam-mcp closed stdout before response id {expected_id}")
        response = json.loads(line)
        if response.get("id") != expected_id:
            raise RuntimeError(f"expected response id {expected_id}, got {response}")
        return response

send({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "lean-beam-install-test", "version": "0"},
    },
})
init = recv(1)
if init.get("result", {}).get("protocolVersion") != "2025-11-25":
    raise RuntimeError(f"unexpected initialize response: {init}")

send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
})
sync = recv(2)
result = sync.get("result")
if not isinstance(result, dict) or result.get("isError") is True:
    raise RuntimeError(f"expected lean_sync to succeed through installed MCP wrapper: {sync}")
structured = result.get("structuredContent")
if not isinstance(structured, dict) or not isinstance(structured.get("file_progress"), dict):
    raise RuntimeError(f"lean_sync result missing structured file_progress: {sync}")
progress = structured["file_progress"]
updates = progress.get("updates")
if not isinstance(updates, int) or isinstance(updates, bool) or updates < 0:
    raise RuntimeError(f"lean_sync result has invalid file_progress updates: {progress}")
done = progress.get("done")
if not isinstance(done, bool):
    raise RuntimeError(f"lean_sync result has invalid file_progress done: {progress}")
if "line" in progress:
    raise RuntimeError(f"lean_sync result should not expose file_progress line: {progress}")
if "totalLines" in progress:
    raise RuntimeError(f"lean_sync result should not expose file_progress totalLines: {progress}")
range_end = progress.get("rangeEndLine")
if range_end is not None and (
    not isinstance(range_end, int) or isinstance(range_end, bool) or range_end < 1
):
    raise RuntimeError(f"lean_sync result has invalid file_progress rangeEndLine: {progress}")
range_start = progress.get("rangeStartLine")
if range_start is not None and (
    not isinstance(range_start, int)
    or isinstance(range_start, bool)
    or range_start < 1
    or (range_end is not None and range_start > range_end)
):
    raise RuntimeError(f"lean_sync result has invalid file_progress rangeStartLine: {progress}")

send({"jsonrpc": "2.0", "id": 3, "method": "shutdown"})
shutdown = recv(3)
if shutdown.get("result") != {}:
    raise RuntimeError(f"unexpected shutdown response: {shutdown}")
proc.stdin.close()
proc.wait(timeout=5)
stderr = proc.stderr.read()
if stderr.strip():
    raise RuntimeError(f"lean-beam-mcp wrote stderr: {stderr}")
print(json.dumps({"ok": True, "progress": progress}, sort_keys=True))
PY
then
  echo "expected installed MCP wrapper smoke to succeed" >&2
  cat "$mcp_smoke_out" >&2
  cat "$mcp_smoke_err" >&2
  remove_tmp_file "$mcp_smoke_out"
  remove_tmp_file "$mcp_smoke_err"
  exit 1
fi
remove_tmp_file "$mcp_smoke_out"
remove_tmp_file "$mcp_smoke_err"

mcp_self_check_out="$("$installed_mcp" --root "$project_root" --self-check PositionEmptyLine.lean)"
if ! printf '%s\n' "$mcp_self_check_out" | grep -q 'Lean Beam MCP self-check passed'; then
  echo "expected installed MCP self-check to report success" >&2
  printf '%s\n' "$mcp_self_check_out" >&2
  exit 1
fi
if ! printf '%s\n' "$mcp_self_check_out" | grep -q 'workspace setup: lean_init_workspace'; then
  echo "expected installed MCP self-check to exercise explicit workspace setup" >&2
  printf '%s\n' "$mcp_self_check_out" >&2
  exit 1
fi

unsupported_project_root="$tmp_root/external-project-unsupported"
rsync -a tests/save_olean_project/ "$unsupported_project_root"/
printf 'leanprover/lean4:v4.26.0\n' > "$unsupported_project_root/lean-toolchain"

unsupported_doctor_out="$("$installed_lean_beam" --root "$unsupported_project_root" doctor)"
if ! printf '%s\n' "$unsupported_doctor_out" | grep -q 'project toolchain supported: false'; then
  echo "expected doctor lean to report unsupported toolchains explicitly" >&2
  printf '%s\n' "$unsupported_doctor_out" >&2
  exit 1
fi
if ! printf '%s\n' "$unsupported_doctor_out" | grep -q 'bundle toolchain fingerprint: (not resolved for rejected toolchain)'; then
  echo "expected doctor lean not to fingerprint unsupported toolchains" >&2
  printf '%s\n' "$unsupported_doctor_out" >&2
  exit 1
fi

unsupported_err="$(mktemp "$tmp_root/install-unsupported-toolchain-XXXXXX")"
if "$installed_lean_beam" --root "$unsupported_project_root" ensure >"$unsupported_err" 2>&1; then
  echo "expected installed wrapper ensure lean to reject an unsupported toolchain" >&2
  cat "$unsupported_err" >&2
  remove_tmp_file "$unsupported_err"
  exit 1
fi
if ! grep -q 'unsupported Lean toolchain: leanprover/lean4:v4.26.0' "$unsupported_err"; then
  echo "expected unsupported toolchain failure to name the rejected toolchain" >&2
  cat "$unsupported_err" >&2
  remove_tmp_file "$unsupported_err"
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -q 'run `lean-beam supported-toolchains` to list the validated toolchains' "$unsupported_err"; then
  echo "expected unsupported toolchain failure to advertise the support registry command" >&2
  cat "$unsupported_err" >&2
  remove_tmp_file "$unsupported_err"
  exit 1
fi
remove_tmp_file "$unsupported_err"

(
  cd "$project_root"
  lake build SaveSmoke/A.lean > /dev/null
  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
)

stale_sync_err="$(mktemp "$tmp_root/install-stale-sync-XXXXXX")"
if "$installed_lean_beam" --root "$project_root" sync SaveSmoke/A.lean >"$stale_sync_err" 2>&1; then
  echo "expected installed wrapper sync to fail on a stale imported target" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
if ! grep -q '"code": "syncBarrierIncomplete"' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import sync failure to expose syncBarrierIncomplete" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -q 'Run `lake build` or fix the upstream module first' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import sync failure to include a recovery hint" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
remove_tmp_file "$stale_sync_err"

project_root_standalone="$tmp_root/external-project-standalone"
rsync -a tests/save_olean_project/ "$project_root_standalone"/

cat > "$project_root_standalone/StandaloneSaveSmoke.lean" <<'EOF'
import SaveSmoke.B

#check bVal
EOF

standalone_sync="$("$installed_lean_beam" --root "$project_root_standalone" sync StandaloneSaveSmoke.lean)"
if ! printf '%s\n' "$standalone_sync" | python3 -c 'import json,sys; payload=json.load(sys.stdin); sys.exit(0 if payload.get("error") is None else 1)'; then
  echo "expected installed wrapper sync to succeed on a standalone file the daemon can open" >&2
  printf '%s\n' "$standalone_sync" >&2
  exit 1
fi

standalone_save_err="$(mktemp "$tmp_root/install-standalone-save-XXXXXX")"
if "$installed_lean_beam" --root "$project_root_standalone" save StandaloneSaveSmoke.lean >"$standalone_save_err" 2>&1; then
  echo "expected installed wrapper save to reject a standalone file outside the Lake module graph" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
if ! grep -q '"code": "saveTargetNotModule"' "$standalone_save_err"; then
  echo "expected installed wrapper standalone save failure to expose saveTargetNotModule" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
if ! grep -q 'save only works for synced files that belong to the current Lake workspace package graph' "$standalone_save_err"; then
  echo "expected installed wrapper standalone save failure to explain the Lake module requirement" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
remove_tmp_file "$standalone_save_err"
