#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# MCP client selection and registration helpers for scripts/install-beam.sh.
# This file is sourced by the installer and intentionally uses its state.
# shellcheck disable=SC2034,SC2154

prompt_mcp_registration_selection() {
  local selection=""
  local target=""
  selection="$(prompt_agent_target_multi_choice \
    "MCP Registration" \
    "Register lean-beam-mcp with:" \
    "MCP clients" \
    "MCP registration" \
    "codex|Codex|c" \
    "claude|Claude Code|claude-code" \
    "opencode|OpenCode|o open-code")"
  register_codex_mcp=0
  register_claude_mcp=0
  register_opencode_mcp=0
  for target in $selection; do
    case "$target" in
      none)
        ;;
      codex)
        register_codex_mcp=1
        ;;
      claude)
        register_claude_mcp=1
        ;;
      opencode)
        register_opencode_mcp=1
        ;;
    esac
  done
}

verify_requested_mcp_clients() {
  if [ "$register_codex_mcp" -eq 1 ]; then
    validate_codex_home
    if ! command -v codex >/dev/null 2>&1; then
      die "cannot register Codex MCP server because codex is not on PATH"
    fi
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    validate_claude_mcp_config_path
    if ! command -v claude >/dev/null 2>&1; then
      die "cannot register Claude Code MCP server because claude is not on PATH"
    fi
  fi
  if [ "$register_opencode_mcp" -eq 1 ]; then
    validate_opencode_mcp_config_path
    if ! command -v python3 >/dev/null 2>&1; then
      die "cannot register OpenCode MCP server because python3 is not on PATH"
    fi
  fi
}

ensure_mcp_config_dir() {
  local path="$1"
  local label="$2"
  require_absolute_path "$path" "$label"
  require_not_root "$path" "$label"
  if [ -e "$path" ]; then
    if [ ! -d "$path" ]; then
      die "refusing to use non-directory $label at $path"
    fi
    return 0
  fi
  mkdir -p "$path"
}

register_codex_mcp_server() {
  ensure_mcp_config_dir "$codex_home" "Codex home"
  CODEX_HOME="$codex_home" codex mcp add lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null
  registered_mcp_targets+=("Codex: lean-beam")
}

register_claude_mcp_server() {
  ensure_mcp_config_dir "$claude_mcp_home" "Claude Code MCP config home"
  HOME="$claude_mcp_home" claude mcp remove --scope user lean-beam >/dev/null 2>&1 || true
  HOME="$claude_mcp_home" claude mcp add --scope user lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null
  registered_mcp_targets+=("Claude Code: lean-beam")
}

write_opencode_mcp_config() {
  local config_path="$1"
  local command_path="$2"
  local config_home=""
  local tmp_path=""
  config_home="$(dirname "$config_path")"
  ensure_mcp_config_dir "$config_home" "OpenCode MCP config home"
  if [ -d "$config_path" ]; then
    die "refusing to replace directory at OpenCode MCP config path: $config_path"
  fi
  if [ -L "$config_path" ]; then
    die "refusing to replace symlinked OpenCode MCP config: $config_path"
  fi
  confirm_path_edit "register OpenCode MCP server" "$config_path"
  tmp_path="$(mktemp "$config_home/.opencode-mcp-XXXXXX")"
  require_path_within "$tmp_path" "$config_home" "OpenCode MCP config temp file"
  if ! python3 - "$config_path" "$tmp_path" "$command_path" <<'PY'
import json
import os
import sys

config_path, tmp_path, command_path = sys.argv[1:]

try:
    if os.path.exists(config_path) and os.path.getsize(config_path) > 0:
        with open(config_path, "r", encoding="utf-8") as f:
            payload = json.load(f)
    else:
        payload = {}
except json.JSONDecodeError as exc:
    print(f"OpenCode MCP config is not strict JSON: {config_path}: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload, dict):
    print(f"OpenCode MCP config must contain a JSON object: {config_path}", file=sys.stderr)
    sys.exit(1)

payload.setdefault("$schema", "https://opencode.ai/config.json")
mcp = payload.setdefault("mcp", {})
if not isinstance(mcp, dict):
    print(f"OpenCode MCP config field must be a JSON object: {config_path}: mcp", file=sys.stderr)
    sys.exit(1)

mcp["lean-beam"] = {
    "type": "local",
    "command": [command_path],
    "enabled": True,
}

with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
  then
    rm -f -- "$tmp_path"
    return 1
  fi
  mv "$tmp_path" "$config_path"
}

register_opencode_mcp_server() {
  write_opencode_mcp_config "$opencode_mcp_config" "$bin_home/lean-beam-mcp"
  registered_mcp_targets+=("OpenCode: lean-beam")
}

register_requested_mcp_servers() {
  if [ "$register_codex_mcp" -eq 1 ]; then
    register_codex_mcp_server
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    register_claude_mcp_server
  fi
  if [ "$register_opencode_mcp" -eq 1 ]; then
    register_opencode_mcp_server
  fi
}
