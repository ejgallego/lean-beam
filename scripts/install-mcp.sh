#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# MCP client selection and registration helpers for scripts/install-beam.sh.
# This file is sourced by the installer and intentionally uses its state.
# shellcheck disable=SC2034,SC2154

prompt_mcp_registration_selection() {
  local reply=""
  local choice=""
  print_section "$style_blue" "MCP Registration"
  printf 'Register lean-beam-mcp with:\n' >&2
  printf '  1) none (default)\n' >&2
  printf '  2) Codex\n' >&2
  printf '  3) Claude Code\n' >&2
  printf '  4) both\n' >&2
  printf 'MCP clients [Enter: none]: ' >&2
  IFS= read -r reply
  choice="$(normalize_choice "$reply")"
  case "$choice" in
    ""|1|n|no|none)
      register_codex_mcp=0
      register_claude_mcp=0
      ;;
    2|c|codex)
      register_codex_mcp=1
      register_claude_mcp=0
      ;;
    3|claude|"claude code"|claude-code)
      register_codex_mcp=0
      register_claude_mcp=1
      ;;
    4|b|both|all)
      register_codex_mcp=1
      register_claude_mcp=1
      ;;
    *)
      die "unknown MCP registration selection: $reply"
      ;;
  esac
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

register_requested_mcp_servers() {
  if [ "$register_codex_mcp" -eq 1 ]; then
    register_codex_mcp_server
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    register_claude_mcp_server
  fi
}
