#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_root/scripts/shared-lib.sh"
. "$repo_root/scripts/install-lib.sh"
# shellcheck source=scripts/install-locations.sh
. "$repo_root/scripts/install-locations.sh"
# shellcheck source=scripts/install-mcp.sh
. "$repo_root/scripts/install-mcp.sh"
codex_home=""
codex_skills_home=""
codex_mcp_config=""
claude_home=""
claude_skills_home=""
claude_mcp_user_config=""
claude_mcp_home=""
claude_mcp_backup_home=""
pi_home=""
pi_skills_home=""
opencode_config_dir=""
opencode_skills_home=""
vibe_home=""
vibe_skills_home=""
vibe_mcp_config=""
bin_home=""
install_root=""
versions_root=""
current_root=""
state_root=""
install_bundles_root=""
beam_cli="$repo_root/.lake/build/bin/beam-cli"
installer_cmd="./scripts/install-beam.sh"
install_codex_skills=0
install_claude_skills=0
install_pi_skills=0
install_opencode_skills=0
install_vibe_skills=0
install_rocq_skill=0
register_codex_mcp=0
register_claude_mcp=0
register_opencode_mcp=0
register_vibe_mcp=0
install_all_supported=0
dont_ask=0
toolchain_selection_explicit=0
skill_selection_explicit=0
mcp_registration_explicit=0
runtime_writes_approved=0
bin_writes_approved=0
source_build_approved=0
requested_toolchains=()
requested_custom_toolchains=()
installed_skill_targets=()
registered_mcp_targets=()
manual_mcp_targets=()
approved_write_homes=()
approved_write_home_count=0
prepared_repo_toolchain=""
prepared_selected_toolchains=()
prepared_custom_toolchains=()
prepared_payload_id=""
prepared_version_root=""
prepared_source_commit=""
style_reset=""
style_bold=""
style_green=""
style_blue=""
style_yellow=""
style_dim=""
beam_lsp_plugin_shared_lib="$(beam_shared_lib_name beam_Beam_LSP)"
install_root_marker=".lean-beam-install-root"
skill_owner_marker=".lean-beam-skill"
install_lock_dir=""

set_bin_home() {
  bin_home="$1"
}

set_install_root() {
  install_root="$1"
  versions_root="$install_root/versions"
  current_root="$install_root/current"
  state_root="$install_root/state"
  install_bundles_root="$state_root/install-bundles"
  install_lock_dir="$install_root/.install-lock"
}

set_codex_home() {
  codex_home="$1"
  codex_skills_home="$codex_home/skills"
  codex_mcp_config="$codex_home/config.toml"
}

set_claude_home() {
  claude_home="$1"
  claude_skills_home="$claude_home/skills"
}

set_claude_mcp_user_config() {
  claude_mcp_user_config="$1"
  claude_mcp_home="$(dirname "$claude_mcp_user_config")"
  claude_mcp_backup_home="$claude_mcp_home/.claude"
}

set_pi_home() {
  pi_home="$1"
  pi_skills_home="$pi_home/skills"
}

set_opencode_config_dir() {
  opencode_config_dir="$1"
  opencode_skills_home="$opencode_config_dir/skills"
}

set_vibe_home() {
  vibe_home="$1"
  vibe_skills_home="$vibe_home/skills"
  vibe_mcp_config="$vibe_home/config.toml"
}

set_bin_home "${BEAM_BIN_HOME:-$HOME/.local/bin}"
set_install_root "${BEAM_INSTALL_ROOT:-$HOME/.local/share/beam}"
set_codex_home "${CODEX_HOME:-$HOME/.codex}"
set_claude_home "${CLAUDE_HOME:-$HOME/.claude}"
set_claude_mcp_user_config "${BEAM_CLAUDE_MCP_CONFIG:-$HOME/.claude.json}"
set_pi_home "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
set_opencode_config_dir "${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
set_vibe_home "${VIBE_HOME:-$HOME/.vibe}"

runtime_payload_spec=(
  "copy|rootFiles|Beam.lean|Beam.lean"
  "copy|rootFiles|lakefile.lean|lakefile.lean"
  "copy|rootFiles|lakefile.toml|lakefile.toml"
  "copy|rootFiles|lake-manifest.json|lake-manifest.json"
  "copy|rootFiles|lean-toolchain|lean-toolchain"
  "copy|rootFiles|supported-lean-toolchains|supported-lean-toolchains"
  "generated|rootFiles|custom-lean-toolchains|custom-lean-toolchains"
  "copy|sourceDirs|Beam|Beam"
  "copy|runtimePaths|.lake/build/bin/beam-cli|libexec/beam-cli"
  "copy|runtimePaths|.lake/build/bin/beam-daemon|libexec/beam-daemon"
  "copy|runtimePaths|.lake/build/bin/beam-client|libexec/beam-client"
  "copy|runtimePaths|.lake/build/bin/lean-beam-mcp|libexec/lean-beam-mcp"
  "copy|runtimePaths|.lake/build/lib/$beam_lsp_plugin_shared_lib|libexec/$beam_lsp_plugin_shared_lib"
  "copy|runtimePaths|.lake/packages|.lake/packages"
  "copy|wrapperPaths|scripts/lean-beam|bin/lean-beam"
  "copy|wrapperPaths|scripts/lean-beam-search|bin/lean-beam-search"
  "copy|wrapperPaths|scripts/lean-beam-mcp|bin/lean-beam-mcp"
)

usage() {
  cat <<EOF
Usage:
  $installer_cmd [OPTIONS]

Installs the local beam command wrappers and self-contained runtime under:
  $install_root

With no flags, an interactive install asks which Lean toolchains, Lean agent skills, and MCP
clients to set up before showing the write plan. Press Enter through the setup prompts for the
minimal runtime install:
  - $bin_home/lean-beam
  - $bin_home/lean-beam-search
  - $bin_home/lean-beam-mcp
  - one prebuilt toolchain build for the repo-pinned Lean toolchain

With --dont-ask and no agent flags, this does not install agent skills.

Optional flags:
  --dont-ask    do not prompt before Beam-owned filesystem edits
  --don't-ask   alias for --dont-ask
  --yes         alias for --dont-ask
  --toolchain    prebuild one supported Lean toolchain; may be repeated
  --custom-toolchain
                prebuild and accept one explicit custom Lean toolchain; may be repeated
  --all-supported
                prebuild every supported Lean toolchain
  --codex       install bundled Lean skill into $codex_skills_home
  --claude      install bundled Lean skill into $claude_skills_home
  --pi          install bundled Lean skill into $pi_skills_home
  --opencode    install bundled Lean skill into $opencode_skills_home
  --vibe        install bundled Lean skill into $vibe_skills_home
  --all-skills  install bundled Lean skill for every supported agent target
  --rocq-skill  also install the optional Rocq skill for the selected agent target(s)
  --codex-mcp   register lean-beam-mcp with Codex
  --codex-home  Codex home for --codex and --codex-mcp
  --claude-mcp  register lean-beam-mcp with Claude Code user config
  --claude-mcp-config
                Claude Code user .claude.json path for --claude-mcp
  --opencode-mcp
                show the OpenCode command and values for adding lean-beam-mcp
  --opencode-config-dir
                OpenCode config directory for --opencode skills
  --pi-home     Pi Agent home for --pi
  --vibe-mcp    register lean-beam-mcp in the Mistral Vibe config
  --vibe-home   Mistral Vibe home for --vibe and --vibe-mcp
  --all-mcp     register Codex/Claude/Mistral Vibe MCP and show OpenCode MCP setup
  -h, --help    show this help

Environment:
  BEAM_BIN_HOME        override the command wrapper directory
  BEAM_INSTALL_ROOT   override the runtime install root
  CODEX_HOME           override the Codex home used by --codex and --codex-mcp
  CLAUDE_HOME          override the Claude home used by --claude
  PI_CODING_AGENT_DIR  override the Pi Agent home used by --pi
  OPENCODE_CONFIG_DIR  override the OpenCode config directory used by --opencode
  VIBE_HOME            override the Mistral Vibe home used by --vibe and --vibe-mcp
  BEAM_CLAUDE_MCP_CONFIG
                        override the Claude Code user .claude.json path used by --claude-mcp

Requirements:
  elan must be on PATH so the installer can prebuild the selected Lean bundle(s)
  custom toolchains must already be known to elan, for example through elan toolchain link
EOF
}

skill_install_names() {
  if [ "$install_rocq_skill" -eq 1 ]; then
    printf 'lean-beam, rocq-beam\n'
  else
    printf 'lean-beam\n'
  fi
}

skill_install_path_summary() {
  local skills_home="$1"
  if [ "$install_rocq_skill" -eq 1 ]; then
    printf '%s/{lean-beam,rocq-beam}\n' "$skills_home"
  else
    printf '%s/lean-beam\n' "$skills_home"
  fi
}

confirm_edit() {
  local action="$1"
  shift
  local reply=""
  local detail=""
  if [ "$dont_ask" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "refusing to $action without confirmation; rerun with --dont-ask to approve Beam-owned installer edits"
  fi
  printf '\nInstaller wants to %s:\n' "$action" >&2
  for detail in "$@"; do
    printf '  %s\n' "$detail" >&2
  done
  printf 'Allow this edit? [y/N] ' >&2
  IFS= read -r reply
  case "$reply" in
    y|Y|yes|YES|Yes)
      ;;
    *)
      die "cancelled before: $action"
      ;;
  esac
}

path_edit_preapproved() {
  local path="$1"
  local approved_home=""
  if [ "$runtime_writes_approved" -eq 1 ] && path_is_within "$path" "$install_root"; then
    return 0
  fi
  if [ "$bin_writes_approved" -eq 1 ]; then
    case "$path" in
      "$bin_home"|"$bin_home/lean-beam"|"$bin_home/lean-beam-search"|"$bin_home/lean-beam-mcp"|"$bin_home/.link-swap-"*)
        return 0
        ;;
    esac
  fi
  if [ "$source_build_approved" -eq 1 ] && path_is_within "$path" "$repo_root/.lake"; then
    return 0
  fi
  if [ "$approved_write_home_count" -gt 0 ]; then
    for approved_home in ${approved_write_homes[@]+"${approved_write_homes[@]}"}; do
      if path_is_within "$path" "$approved_home"; then
        return 0
      fi
    done
  fi
  return 1
}

confirm_path_edit() {
  local action="$1"
  local path="$2"
  shift 2
  if [ "$dont_ask" -eq 1 ] || path_edit_preapproved "$path"; then
    return 0
  fi
  confirm_edit "$action" "$path" "$@"
}

ensure_dir_for_install() {
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
  confirm_path_edit "create $label directory" "$path"
  mkdir -p "$path"
}

require_owned_staging_dir() {
  local path="$1"
  require_path_within "$path" "$install_root" "staging dir"
  case "$(basename "$path")" in
    .staging-*)
      ;;
    *)
      die "refusing to touch unexpected staging dir: $path"
      ;;
  esac
}

ensure_replaceable_path() {
  local path="$1"
  local root="$2"
  local label="$3"
  require_path_within "$path" "$root" "$label"
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    die "refusing to replace directory at $path"
  fi
}

ensure_install_root_claimable() {
  local entry=""
  local base=""
  if [ ! -e "$install_root" ]; then
    return 0
  fi
  if [ -L "$install_root" ]; then
    die "refusing to use symlinked install root: $install_root"
  fi
  if [ ! -d "$install_root" ]; then
    die "refusing to use non-directory install root: $install_root"
  fi
  if [ -f "$install_root/$install_root_marker" ]; then
    return 0
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    base="$(basename "$entry")"
    case "$base" in
      current|versions|state|"$install_root_marker"|.staging-*|.link-swap-*|.install-lock)
        ;;
      *)
        die "refusing to claim install root with unrecognized existing path: $entry"
        ;;
    esac
  done < <(find "$install_root" -mindepth 1 -maxdepth 1 -print)
}

write_install_root_marker() {
  local marker="$install_root/$install_root_marker"
  if [ -f "$marker" ]; then
    return 0
  fi
  confirm_path_edit "mark Beam install root as installer-owned" "$marker"
  {
    printf 'schema=1\n'
    printf 'owner=lean-beam\n'
    printf 'root=%s\n' "$install_root"
  } >"$marker"
}

ensure_install_root_ready() {
  require_absolute_path "$install_root" "install root"
  require_not_root "$install_root" "install root"
  ensure_install_root_claimable
  ensure_dir_for_install "$install_root" "install root"
  write_install_root_marker
}

release_install_lock() {
  if [ -d "$install_lock_dir" ] && [ -f "$install_lock_dir/pid" ]; then
    rm -f -- "$install_lock_dir/pid"
    rmdir "$install_lock_dir" 2>/dev/null || true
  fi
}

acquire_install_lock() {
  require_path_within "$install_lock_dir" "$install_root" "install lock"
  if mkdir "$install_lock_dir"; then
    printf '%s\n' "$$" >"$install_lock_dir/pid"
    trap 'release_install_lock' EXIT
  else
    die "another Beam install appears to be running: $install_lock_dir"
  fi
}

symlink_target_text() {
  local link_path="$1"
  local target=""
  local link_dir=""
  target="$(readlink "$link_path")"
  require_no_parent_refs "$target" "symlink target"
  case "$target" in
    /*)
      printf '%s\n' "$target"
      ;;
    *)
      link_dir="$(dirname "$link_path")"
      printf '%s/%s\n' "$link_dir" "$target"
      ;;
  esac
}

ensure_beam_symlink_or_absent() {
  local path="$1"
  local root="$2"
  local label="$3"
  local target=""
  require_path_within "$path" "$root" "$label"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ ! -L "$path" ]; then
    if [ -d "$path" ]; then
      die "refusing to replace directory at $path"
    fi
    die "refusing to replace non-Beam path at $path"
  fi
  target="$(symlink_target_text "$path")"
  require_path_within "$target" "$install_root" "$label target"
}

remove_owned_staging_dir() {
  local path="$1"
  require_owned_staging_dir "$path"
  rm -rf -- "$path"
}

copy_repo_path_if_present() {
  local src="$1"
  local dest="$2"
  local dest_root="$3"
  require_path_within "$src" "$repo_root" "copy source"
  require_path_within "$dest" "$dest_root" "copy destination"
  if [ -e "$src" ]; then
    ensure_dir_for_install "$(dirname "$dest")" "copy destination parent"
    cp -Rp "$src" "$dest"
  fi
}

move_staging_dir_into_versions() {
  local staging_dir="$1"
  local version_dir="$2"
  require_owned_staging_dir "$staging_dir"
  require_path_within "$version_dir" "$versions_root" "version dir"
  if [ -e "$version_dir" ]; then
    if [ ! -d "$version_dir" ]; then
      die "refusing to use non-directory version path: $version_dir"
    fi
    if [ ! -f "$version_dir/manifest.json" ]; then
      die "refusing to reuse unmarked existing version directory: $version_dir"
    fi
  fi
  confirm_path_edit "publish staged runtime version" "$version_dir"
  mv "$staging_dir" "$version_dir"
}

replace_symlink_atomically() {
  local target="$1"
  local link_path="$2"
  local allowed_root="$3"
  local label="$4"
  local link_dir=""
  local tmp_dir=""
  local tmp_link=""
  require_absolute_path "$target" "$label target"
  ensure_beam_symlink_or_absent "$link_path" "$allowed_root" "$label"
  link_dir="$(dirname "$link_path")"
  require_path_within "$link_dir" "$allowed_root" "$label parent"
  ensure_dir_for_install "$link_dir" "$label parent"
  confirm_path_edit "publish $label" "$link_path" "$link_path -> $target"
  tmp_dir="$(mktemp -d "$link_dir/.link-swap-XXXXXX")"
  require_path_within "$tmp_dir" "$link_dir" "$label temp dir"
  tmp_link="$tmp_dir/link"
  ln -s "$target" "$tmp_link"
  rm -f -- "$link_path"
  mv "$tmp_link" "$link_path"
  rmdir "$tmp_dir"
}

verify_publish_targets() {
  ensure_beam_symlink_or_absent "$current_root" "$install_root" "current link"
  ensure_beam_symlink_or_absent "$bin_home/lean-beam" "$bin_home" "lean-beam wrapper link"
  ensure_beam_symlink_or_absent "$bin_home/lean-beam-search" "$bin_home" "lean-beam-search link"
  ensure_beam_symlink_or_absent "$bin_home/lean-beam-mcp" "$bin_home" "lean-beam-mcp link"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dont-ask|"--don't-ask"|--yes)
        dont_ask=1
        ;;
      --toolchain)
        if [ "$#" -lt 2 ]; then
          die "missing value for --toolchain"
        fi
        toolchain_selection_explicit=1
        requested_toolchains+=("$2")
        shift
        ;;
      --custom-toolchain)
        if [ "$#" -lt 2 ]; then
          die "missing value for --custom-toolchain"
        fi
        toolchain_selection_explicit=1
        requested_custom_toolchains+=("$2")
        shift
        ;;
      --all-supported)
        toolchain_selection_explicit=1
        install_all_supported=1
        ;;
      --codex)
        skill_selection_explicit=1
        install_codex_skills=1
        ;;
      --claude)
        skill_selection_explicit=1
        install_claude_skills=1
        ;;
      --pi)
        skill_selection_explicit=1
        install_pi_skills=1
        ;;
      --opencode)
        skill_selection_explicit=1
        install_opencode_skills=1
        ;;
      --vibe)
        skill_selection_explicit=1
        install_vibe_skills=1
        ;;
      --all-skills)
        skill_selection_explicit=1
        install_codex_skills=1
        install_claude_skills=1
        install_pi_skills=1
        install_opencode_skills=1
        install_vibe_skills=1
        ;;
      --rocq-skill)
        install_rocq_skill=1
        ;;
      --codex-mcp)
        mcp_registration_explicit=1
        register_codex_mcp=1
        ;;
      --codex-home)
        if [ "$#" -lt 2 ]; then
          die "missing value for --codex-home"
        fi
        set_codex_home "$2"
        shift
        ;;
      --claude-mcp)
        mcp_registration_explicit=1
        register_claude_mcp=1
        ;;
      --claude-mcp-config)
        if [ "$#" -lt 2 ]; then
          die "missing value for --claude-mcp-config"
        fi
        set_claude_mcp_user_config "$2"
        shift
        ;;
      --opencode-mcp)
        mcp_registration_explicit=1
        register_opencode_mcp=1
        ;;
      --opencode-config-dir)
        if [ "$#" -lt 2 ]; then
          die "missing value for --opencode-config-dir"
        fi
        set_opencode_config_dir "$2"
        shift
        ;;
      --pi-home)
        if [ "$#" -lt 2 ]; then
          die "missing value for --pi-home"
        fi
        set_pi_home "$2"
        shift
        ;;
      --vibe-mcp)
        mcp_registration_explicit=1
        register_vibe_mcp=1
        ;;
      --vibe-home)
        if [ "$#" -lt 2 ]; then
          die "missing value for --vibe-home"
        fi
        set_vibe_home "$2"
        shift
        ;;
      --all-mcp)
        mcp_registration_explicit=1
        register_codex_mcp=1
        register_claude_mcp=1
        register_opencode_mcp=1
        register_vibe_mcp=1
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        echo "unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

validate_install_config() {
  require_absolute_path "$repo_root" "repo root"
  require_absolute_path "$bin_home" "bin home"
  require_absolute_path "$install_root" "install root"
  require_not_root "$bin_home" "bin home"
  require_not_root "$install_root" "install root"
  require_path_within "$versions_root" "$install_root" "versions root"
  require_path_within "$current_root" "$install_root" "current link"
  require_path_within "$state_root" "$install_root" "state root"
  require_path_within "$install_bundles_root" "$state_root" "install bundle root"
}

read_supported_toolchains() {
  local registry="$repo_root/supported-lean-toolchains"
  if [ -f "$registry" ]; then
    awk '
      {
        sub(/\r$/, "")
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line != "" && substr(line, 1, 1) != "#") {
          print line
        }
      }
    ' "$registry"
  else
    if [ ! -x "$beam_cli" ]; then
      die "missing supported Lean toolchain registry at $registry"
    fi
    "$beam_cli" supported-toolchains lean
  fi
}

load_supported_toolchains() {
  supported_toolchains=()
  local toolchain=""
  while IFS= read -r toolchain; do
    [ -n "$toolchain" ] || continue
    supported_toolchains+=("$toolchain")
  done < <(read_supported_toolchains)
}

require_supported_toolchains_loaded() {
  if [ "${#supported_toolchains[@]}" -eq 0 ]; then
    die "beam CLI reported no supported Lean toolchains"
  fi
}

append_unique_selected_toolchain() {
  local toolchain="$1"
  if [ "${#selected[@]}" -eq 0 ] || ! array_contains "$toolchain" ${selected[@]+"${selected[@]}"}; then
    selected+=("$toolchain")
  fi
}

append_unique_custom_toolchain() {
  local toolchain="$1"
  if [ "${#custom_selected[@]}" -eq 0 ] || ! array_contains "$toolchain" ${custom_selected[@]+"${custom_selected[@]}"}; then
    custom_selected+=("$toolchain")
  fi
}

validate_custom_toolchain_name() {
  local toolchain="$1"
  if [ -z "$toolchain" ]; then
    die "custom Lean toolchain must not be empty"
  fi
  case "$toolchain" in
    *[[:space:]]*)
      die "custom Lean toolchain must not contain whitespace: $toolchain"
      ;;
  esac
}

prompt_toolchain_selection() {
  local repo_toolchain="$1"
  local supported_toolchains=()
  local selected=()
  local custom_selected=()
  local toolchain=""
  local custom_toolchain=""
  local reply=""
  local token=""
  local index=""
  local ordinal=1

  load_supported_toolchains
  require_supported_toolchains_loaded

  print_section "$style_blue" "Lean Toolchains"
  printf 'Supported toolchains:\n' >&2
  for toolchain in ${supported_toolchains[@]+"${supported_toolchains[@]}"}; do
    if [ "$toolchain" = "$repo_toolchain" ]; then
      printf '  %d) %s (default)\n' "$ordinal" "$toolchain" >&2
    else
      printf '  %d) %s\n' "$ordinal" "$toolchain" >&2
    fi
    ordinal=$((ordinal + 1))
  done
  printf 'Prebuild toolchains [Enter: %s; numbers, names, custom:<name>, or all]: ' "$repo_toolchain" >&2
  IFS= read -r reply
  reply="${reply//,/ }"
  if [ -z "$reply" ]; then
    requested_toolchains=("$repo_toolchain")
    requested_custom_toolchains=()
    install_all_supported=0
    return 0
  fi
  for token in $reply; do
    case "$(normalize_choice "$token")" in
      all)
        install_all_supported=1
        ;;
      custom:*)
        custom_toolchain="${token#*:}"
        validate_custom_toolchain_name "$custom_toolchain"
        append_unique_custom_toolchain "$custom_toolchain"
        ;;
      *[!0-9]*)
        if ! array_contains "$token" ${supported_toolchains[@]+"${supported_toolchains[@]}"}; then
          die "unsupported Lean toolchain selected for install: $token; use custom:$token for an explicit local toolchain"
        fi
        append_unique_selected_toolchain "$token"
        ;;
      *)
        if [ "$token" -lt 1 ] || [ "$token" -gt "${#supported_toolchains[@]}" ]; then
          die "toolchain selection out of range: $token"
        fi
        index=$((token - 1))
        toolchain="${supported_toolchains[$index]}"
        append_unique_selected_toolchain "$toolchain"
        ;;
    esac
  done
  if [ "$install_all_supported" -eq 1 ]; then
    requested_toolchains=()
  elif [ "${#selected[@]}" -gt 0 ]; then
    requested_toolchains=(${selected[@]+"${selected[@]}"})
  elif [ "${#custom_selected[@]}" -eq 0 ]; then
    die "no Lean toolchains selected"
  else
    requested_toolchains=()
  fi
  requested_custom_toolchains=(${custom_selected[@]+"${custom_selected[@]}"})
}

prompt_skill_selection() {
  local selection=""
  local target=""
  selection="$(prompt_agent_target_multi_choice \
    "Agent Skills" \
    "Lean agent skill targets to install:" \
    "Install Lean skill" \
    "skill" \
    "codex|Codex ($codex_skills_home)|c" \
    "claude|Claude Code ($claude_skills_home)|claude-code" \
    "pi|Pi Agent ($pi_skills_home)|p pi-agent" \
    "vibe|Mistral Vibe ($vibe_skills_home)|v mistral mistral-vibe" \
    "opencode|OpenCode ($opencode_skills_home)|o open-code")"
  install_codex_skills=0
  install_claude_skills=0
  install_pi_skills=0
  install_opencode_skills=0
  install_vibe_skills=0
  for target in $selection; do
    case "$target" in
      none)
        ;;
      codex)
        install_codex_skills=1
        ;;
      claude)
        install_claude_skills=1
        ;;
      pi)
        install_pi_skills=1
        ;;
      opencode)
        install_opencode_skills=1
        ;;
      vibe)
        install_vibe_skills=1
        ;;
    esac
  done
}

validate_skill_selection() {
  if [ "$install_rocq_skill" -eq 1 ] \
    && [ "$install_codex_skills" -eq 0 ] \
    && [ "$install_claude_skills" -eq 0 ] \
    && [ "$install_pi_skills" -eq 0 ] \
    && [ "$install_opencode_skills" -eq 0 ] \
    && [ "$install_vibe_skills" -eq 0 ]; then
    die "--rocq-skill requires --codex, --claude, --pi, --opencode, --vibe, --all-skills, or an interactive skill target"
  fi
}

maybe_prompt_interactive_choices() {
  local repo_toolchain="$1"
  if [ "$dont_ask" -eq 1 ] || [ ! -t 0 ]; then
    return 0
  fi
  if [ "$toolchain_selection_explicit" -eq 0 ]; then
    prompt_toolchain_selection "$repo_toolchain"
  fi
  if [ "$skill_selection_explicit" -eq 0 ]; then
    prompt_skill_selection
  fi
  if [ "$mcp_registration_explicit" -eq 0 ]; then
    prompt_mcp_registration_selection
  fi
}

resolve_prepared_toolchain_selection() {
  local repo_toolchain="$1"
  local supported_toolchains=()
  local selected=()
  local custom_selected=()
  local toolchain=""

  if [ "$install_all_supported" -eq 1 ] && [ "${#requested_toolchains[@]}" -gt 0 ]; then
    die "cannot combine --all-supported with --toolchain"
  fi

  load_supported_toolchains
  require_supported_toolchains_loaded

  if [ "$install_all_supported" -eq 1 ]; then
    selected=(${supported_toolchains[@]+"${supported_toolchains[@]}"})
  elif [ "${#requested_toolchains[@]}" -gt 0 ]; then
    for toolchain in ${requested_toolchains[@]+"${requested_toolchains[@]}"}; do
      if ! array_contains "$toolchain" ${supported_toolchains[@]+"${supported_toolchains[@]}"}; then
        die "unsupported Lean toolchain requested for install: $toolchain"
      fi
      append_unique_selected_toolchain "$toolchain"
    done
  elif [ "${#requested_custom_toolchains[@]}" -gt 0 ]; then
    for toolchain in ${requested_custom_toolchains[@]+"${requested_custom_toolchains[@]}"}; do
      if array_contains "$toolchain" ${supported_toolchains[@]+"${supported_toolchains[@]}"}; then
        append_unique_selected_toolchain "$toolchain"
      fi
    done
  else
    if ! array_contains "$repo_toolchain" ${supported_toolchains[@]+"${supported_toolchains[@]}"}; then
      die "pinned Lean toolchain is not in supported-lean-toolchains: $repo_toolchain"
    fi
    selected=("$repo_toolchain")
  fi

  for toolchain in ${requested_custom_toolchains[@]+"${requested_custom_toolchains[@]}"}; do
    validate_custom_toolchain_name "$toolchain"
    if array_contains "$toolchain" ${supported_toolchains[@]+"${supported_toolchains[@]}"}; then
      continue
    fi
    append_unique_custom_toolchain "$toolchain"
  done

  if [ "${#selected[@]}" -eq 0 ] && [ "${#custom_selected[@]}" -eq 0 ]; then
    die "no Lean toolchains selected"
  fi

  prepared_selected_toolchains=()
  for toolchain in ${selected[@]+"${selected[@]}"}; do
    prepared_selected_toolchains+=("$toolchain")
  done
  for toolchain in ${custom_selected[@]+"${custom_selected[@]}"}; do
    if [ "${#prepared_selected_toolchains[@]}" -eq 0 ] \
      || ! array_contains "$toolchain" ${prepared_selected_toolchains[@]+"${prepared_selected_toolchains[@]}"}; then
      prepared_selected_toolchains+=("$toolchain")
    fi
  done
  prepared_custom_toolchains=(${custom_selected[@]+"${custom_selected[@]}"})
}

runtime_artifacts_ready() {
  [ -x "$beam_cli" ] \
    && [ -x "$repo_root/.lake/build/bin/beam-daemon" ] \
    && [ -x "$repo_root/.lake/build/bin/beam-client" ] \
    && [ -x "$repo_root/.lake/build/bin/lean-beam-mcp" ] \
    && [ -f "$repo_root/.lake/build/lib/$beam_lsp_plugin_shared_lib" ]
}

print_install_plan() {
  local toolchain=""
  local display_toolchain=""
  print_section "$style_blue" "Install Plan"
  print_field "runtime" "$install_root"
  print_field "commands" "$bin_home/{lean-beam,lean-beam-search,lean-beam-mcp}"
  print_field "bundles" "$install_bundles_root"
  if [ "${#prepared_selected_toolchains[@]}" -gt 0 ]; then
    local first_toolchain=1
    for toolchain in ${prepared_selected_toolchains[@]+"${prepared_selected_toolchains[@]}"}; do
      display_toolchain="$toolchain"
      if array_contains "$toolchain" ${prepared_custom_toolchains[@]+"${prepared_custom_toolchains[@]}"}; then
        display_toolchain="$toolchain (custom)"
      fi
      if [ "$first_toolchain" -eq 1 ]; then
        print_field "toolchains" "$display_toolchain"
        first_toolchain=0
      else
        print_field "" "$display_toolchain"
      fi
    done
  fi
  if [ "$install_codex_skills" -eq 0 ] && [ "$install_claude_skills" -eq 0 ] \
    && [ "$install_pi_skills" -eq 0 ] && [ "$install_opencode_skills" -eq 0 ] \
    && [ "$install_vibe_skills" -eq 0 ]; then
    print_field "skills" "none"
  else
    if [ "$install_codex_skills" -eq 1 ]; then
      print_field "Codex skills" "$(skill_install_path_summary "$codex_skills_home")"
    fi
    if [ "$install_claude_skills" -eq 1 ]; then
      print_field "Claude skills" "$(skill_install_path_summary "$claude_skills_home")"
    fi
    if [ "$install_pi_skills" -eq 1 ]; then
      print_field "Pi Agent skills" "$(skill_install_path_summary "$pi_skills_home")"
    fi
    if [ "$install_opencode_skills" -eq 1 ]; then
      print_field "OpenCode skills" "$(skill_install_path_summary "$opencode_skills_home")"
    fi
    if [ "$install_vibe_skills" -eq 1 ]; then
      print_field "Mistral Vibe skills" "$(skill_install_path_summary "$vibe_skills_home")"
    fi
  fi
  if [ "$register_codex_mcp" -eq 0 ] && [ "$register_claude_mcp" -eq 0 ] \
    && [ "$register_opencode_mcp" -eq 0 ] && [ "$register_vibe_mcp" -eq 0 ]; then
    print_field "MCP setup" "none"
  else
    if [ "$register_codex_mcp" -eq 1 ]; then
      print_field "Codex MCP" "lean-beam -> $bin_home/lean-beam-mcp"
    fi
    if [ "$register_claude_mcp" -eq 1 ]; then
      print_field "Claude MCP" "lean-beam -> $bin_home/lean-beam-mcp"
    fi
    if [ "$register_opencode_mcp" -eq 1 ]; then
      print_field "OpenCode MCP" "manual: opencode mcp add"
    fi
    if [ "$register_vibe_mcp" -eq 1 ]; then
      print_field "Mistral Vibe MCP" "lean-beam -> $bin_home/lean-beam-mcp"
    fi
  fi
  print_field "source build" "$repo_root/.lake"
  if [ "$dont_ask" -eq 0 ]; then
    print_field "approval" "one grouped write-permission prompt"
  else
    print_field "approval" "--dont-ask supplied; safety checks still apply"
  fi
}

hash_tree() {
  local root="$1"
  local tool
  tool="$(hash_tool)"
  if [ "$tool" = "sha256sum" ]; then
    (
      cd "$root"
      find . -type f -print | LC_ALL=C sort | while IFS= read -r rel; do
        sha256sum "$rel"
      done | sha256sum | awk '{print $1}'
    )
  else
    (
      cd "$root"
      find . -type f -print | LC_ALL=C sort | while IFS= read -r rel; do
        shasum -a 256 "$rel"
      done | shasum -a 256 | awk '{print $1}'
    )
  fi
}

ensure_runtime_artifacts() {
  confirm_path_edit "build Beam runtime artifacts in the source checkout" "$repo_root/.lake/build"
  echo "building beam runtime artifacts" >&2
  (
    cd "$repo_root"
    lake build Beam.LSP:shared beam-cli beam-daemon beam-client lean-beam-mcp
  )
  if ! runtime_artifacts_ready; then
    die "Beam runtime build completed but required artifacts are missing"
  fi
}

repo_source_commit() {
  git -C "$repo_root" rev-parse HEAD 2>/dev/null || true
}

require_elan() {
  if ! command -v elan >/dev/null 2>&1; then
    echo "missing elan on PATH; beam install requires elan to prebuild the pinned Lean bundle" >&2
    exit 1
  fi
}

require_repo_toolchain() {
  local toolchain="$1"
  if [ -z "$toolchain" ]; then
    echo "missing pinned Lean toolchain in $repo_root/lean-toolchain; refusing incomplete install" >&2
    exit 1
  fi
}

stage_runtime_tree() {
  local dest="$1"
  local entry=""
  local mode=""
  local src_rel=""
  local dest_rel=""
  local toolchain=""
  mkdir -p "$dest"
  for entry in ${runtime_payload_spec[@]+"${runtime_payload_spec[@]}"}; do
    IFS='|' read -r mode _ src_rel dest_rel <<< "$entry"
    case "$mode" in
      copy)
        copy_repo_path_if_present "$repo_root/$src_rel" "$dest/$dest_rel" "$dest"
        ;;
      generated)
        case "$dest_rel" in
          custom-lean-toolchains)
            ensure_dir_for_install "$(dirname "$dest/$dest_rel")" "custom toolchain registry parent"
            : > "$dest/$dest_rel"
            for toolchain in ${prepared_custom_toolchains[@]+"${prepared_custom_toolchains[@]}"}; do
              printf '%s\n' "$toolchain" >> "$dest/$dest_rel"
            done
            ;;
          *)
            die "unknown generated runtime payload: $dest_rel"
            ;;
        esac
        ;;
      *)
        die "unknown runtime payload mode: $mode"
        ;;
    esac
  done
}

stage_install_version() {
  local dest="$1"
  stage_runtime_tree "$dest"
}

write_install_manifest() {
  local dest="$1"
  local payload_id="$2"
  local source_commit="$3"
  local source_commit_arg="-"
  shift 3
  if [ -n "$source_commit" ]; then
    source_commit_arg="$source_commit"
  fi
  "$beam_cli" install-manifest "$payload_id" "$source_commit_arg" "$@" >"$dest"
}

prebuild_bundle() {
  local runtime_home="$1"
  local toolchain="$2"
  local bundle_home="$3"
  ensure_dir_for_install "$bundle_home" "install bundle cache"
  confirm_path_edit "prebuild Beam bundle" "$bundle_home" "$toolchain"
  BEAM_HOME="$runtime_home" BEAM_INSTALL_BUNDLE_DIR="$bundle_home" \
    "$runtime_home/libexec/beam-cli" bundle-install "$toolchain"
}

ensure_skill_target_replaceable() {
  local target="$1"
  local label="$2"
  require_absolute_path "$target" "$label skill directory"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ -L "$target" ]; then
    die "refusing to replace symlinked $label skill directory at $target"
  fi
  if [ ! -d "$target" ]; then
    die "refusing to replace non-directory $label skill path at $target"
  fi
  if [ ! -f "$target/$skill_owner_marker" ]; then
    die "refusing to replace unmarked existing $label skill directory at $target"
  fi
}

install_one_skill() {
  local source_dir="$1"
  local target_dir="$2"
  local label="$3"
  local parent=""
  local staging_dir=""
  require_path_within "$source_dir" "$repo_root" "$label skill source"
  require_absolute_path "$target_dir" "$label skill target"
  parent="$(dirname "$target_dir")"
  ensure_dir_for_install "$parent" "$label skill parent"
  ensure_skill_target_replaceable "$target_dir" "$label"
  confirm_path_edit "install $label skill" "$target_dir"
  staging_dir="$(mktemp -d "$parent/.${label}.staging-XXXXXX")"
  require_path_within "$staging_dir" "$parent" "$label skill staging directory"
  cp -Rp "$source_dir/." "$staging_dir/"
  {
    printf 'schema=1\n'
    printf 'owner=lean-beam\n'
    printf 'skill=%s\n' "$label"
  } >"$staging_dir/$skill_owner_marker"
  if [ -e "$target_dir" ]; then
    rm -rf -- "$target_dir"
  fi
  mv "$staging_dir" "$target_dir"
}

install_skills() {
  local skills_home="$1"
  require_absolute_path "$skills_home" "skills home"
  ensure_dir_for_install "$skills_home" "skills home"
  install_one_skill "$repo_root/skills/lean-beam" "$skills_home/lean-beam" "lean-beam"
  if [ "$install_rocq_skill" -eq 1 ]; then
    install_one_skill "$repo_root/skills/rocq-beam" "$skills_home/rocq-beam" "rocq-beam"
  fi
}

install_skill_target() {
  local label="$1"
  local skills_home="$2"
  install_skills "$skills_home"
  printf '%s: %s: %s\n' "$label" "$(skill_install_names)" "$skills_home"
}

verify_skill_home_targets() {
  local skills_home="$1"
  require_absolute_path "$skills_home" "skills home"
  ensure_skill_target_replaceable "$skills_home/lean-beam" "lean-beam"
  if [ "$install_rocq_skill" -eq 1 ]; then
    ensure_skill_target_replaceable "$skills_home/rocq-beam" "rocq-beam"
  fi
}

verify_requested_skill_targets() {
  if [ "$install_codex_skills" -eq 1 ]; then
    verify_skill_home_targets "$codex_skills_home"
  fi
  if [ "$install_claude_skills" -eq 1 ]; then
    verify_skill_home_targets "$claude_skills_home"
  fi
  if [ "$install_pi_skills" -eq 1 ]; then
    verify_skill_home_targets "$pi_skills_home"
  fi
  if [ "$install_opencode_skills" -eq 1 ]; then
    verify_skill_home_targets "$opencode_skills_home"
  fi
  if [ "$install_vibe_skills" -eq 1 ]; then
    verify_skill_home_targets "$vibe_skills_home"
  fi
}

prepare_install_environment() {
  require_elan
  prepared_repo_toolchain="$(awk 'NR==1 {print $1}' "$repo_root/lean-toolchain")"
  require_repo_toolchain "$prepared_repo_toolchain"
  maybe_prompt_interactive_choices "$prepared_repo_toolchain"
  resolve_prepared_toolchain_selection "$prepared_repo_toolchain"
  validate_skill_selection
  print_install_plan
  approve_requested_writes
  ensure_install_root_ready
  acquire_install_lock
  ensure_runtime_artifacts
  ensure_dir_for_install "$bin_home" "bin home"
  ensure_dir_for_install "$versions_root" "versions root"
  ensure_dir_for_install "$state_root" "state root"
}

prepare_install_version() {
  local staging_root="$1"
  stage_install_version "$staging_root"
  prepared_payload_id="$(hash_tree "$staging_root")"
  prepared_version_root="$versions_root/$prepared_payload_id"
  prepared_source_commit="$(repo_source_commit)"
  write_install_manifest \
    "$staging_root/manifest.json" \
    "$prepared_payload_id" \
    "$prepared_source_commit" \
    ${prepared_selected_toolchains[@]+"${prepared_selected_toolchains[@]}"}
  if [ ! -d "$prepared_version_root" ]; then
    move_staging_dir_into_versions "$staging_root" "$prepared_version_root"
  else
    if [ ! -f "$prepared_version_root/manifest.json" ]; then
      die "refusing to reuse unmarked existing version directory: $prepared_version_root"
    fi
    remove_owned_staging_dir "$staging_root"
  fi
  if [ ! -f "$prepared_version_root/manifest.json" ]; then
    write_install_manifest \
      "$prepared_version_root/manifest.json" \
      "$prepared_payload_id" \
      "$prepared_source_commit" \
      ${prepared_selected_toolchains[@]+"${prepared_selected_toolchains[@]}"}
  fi
}

prebuild_install_bundles() {
  local version_root="$1"
  shift
  local toolchain=""
  for toolchain in "$@"; do
    echo "prebuilding beam bundle for $toolchain" >&2
    prebuild_bundle "$version_root" "$toolchain" "$install_bundles_root"
  done
}

publish_runtime() {
  local version_root="$1"
  replace_symlink_atomically "$version_root" "$current_root" "$install_root" "current link"
  replace_symlink_atomically "$current_root/bin/lean-beam" "$bin_home/lean-beam" "$bin_home" "lean-beam wrapper link"
  replace_symlink_atomically "$current_root/bin/lean-beam-search" "$bin_home/lean-beam-search" "$bin_home" "lean-beam-search link"
  replace_symlink_atomically "$current_root/bin/lean-beam-mcp" "$bin_home/lean-beam-mcp" "$bin_home" "lean-beam-mcp link"
}

install_requested_skills() {
  local target=""
  if [ "$install_codex_skills" -eq 1 ]; then
    target="$(install_skill_target "Codex" "$codex_skills_home")"
    installed_skill_targets+=("$target")
  fi
  if [ "$install_claude_skills" -eq 1 ]; then
    target="$(install_skill_target "Claude Code" "$claude_skills_home")"
    installed_skill_targets+=("$target")
  fi
  if [ "$install_pi_skills" -eq 1 ]; then
    target="$(install_skill_target "Pi Agent" "$pi_skills_home")"
    installed_skill_targets+=("$target")
  fi
  if [ "$install_opencode_skills" -eq 1 ]; then
    target="$(install_skill_target "OpenCode" "$opencode_skills_home")"
    installed_skill_targets+=("$target")
  fi
  if [ "$install_vibe_skills" -eq 1 ]; then
    target="$(install_skill_target "Mistral Vibe" "$vibe_skills_home")"
    installed_skill_targets+=("$target")
  fi
}

target_list_contains_prefix() {
  local prefix="$1"
  shift
  local target=""
  for target in "$@"; do
    case "$target" in
      "$prefix":*)
        return 0
        ;;
    esac
  done
  return 1
}

install_path_status() {
  if path_contains_dir "$bin_home"; then
    printf 'ready for direct lean-beam and lean-beam-mcp use in this shell\n'
  else
    printf '%s is not on PATH yet\n' "$bin_home"
  fi
}

display_toolchain_for_summary() {
  local toolchain="$1"
  if array_contains "$toolchain" ${prepared_custom_toolchains[@]+"${prepared_custom_toolchains[@]}"}; then
    printf '%s (custom)\n' "$toolchain"
  else
    printf '%s\n' "$toolchain"
  fi
}

print_prebuilt_toolchain_summary() {
  local toolchain=""
  if [ "$#" -eq 0 ]; then
    print_field "prebuilt toolchains" "none"
    return 0
  fi
  print_field "prebuilt toolchains" "$(display_toolchain_for_summary "$1")"
  shift
  for toolchain in "$@"; do
    print_field "" "$(display_toolchain_for_summary "$toolchain")"
  done
}

skill_state_for_summary() {
  if [ "$1" -eq 1 ]; then
    printf '%s installed\n' "$(skill_install_names)"
  else
    printf 'not installed\n'
  fi
}

mcp_state_for_summary() {
  if [ "$1" -eq 1 ]; then
    printf 'registered\n'
  else
    printf 'not registered\n'
  fi
}

print_codex_followup_hint() {
  local skill_installed="$1"
  local mcp_registered="$2"
  if [ "$skill_installed" -eq 0 ] && [ "$mcp_registered" -eq 0 ]; then
    print_field "Codex setup" "$installer_cmd --codex --codex-mcp"
  elif [ "$skill_installed" -eq 0 ]; then
    print_field "Codex Lean skill" "$installer_cmd --codex"
  elif [ "$mcp_registered" -eq 0 ]; then
    print_field "Codex MCP" "$installer_cmd --codex-mcp"
  fi
}

print_claude_followup_hint() {
  local skill_installed="$1"
  local mcp_registered="$2"
  if [ "$skill_installed" -eq 0 ] && [ "$mcp_registered" -eq 0 ]; then
    print_field "Claude Code setup" "$installer_cmd --claude --claude-mcp"
  elif [ "$skill_installed" -eq 0 ]; then
    print_field "Claude Lean skill" "$installer_cmd --claude"
  elif [ "$mcp_registered" -eq 0 ]; then
    print_field "Claude Code MCP" "$installer_cmd --claude-mcp"
  fi
}

print_pi_followup_hint() {
  local skill_installed="$1"
  if [ "$skill_installed" -eq 0 ]; then
    print_field "Pi Agent Lean skill" "$installer_cmd --pi"
  fi
}

print_vibe_followup_hint() {
  local skill_installed="$1"
  local mcp_registered="$2"
  if [ "$skill_installed" -eq 0 ] && [ "$mcp_registered" -eq 0 ]; then
    print_field "Mistral Vibe setup" "$installer_cmd --vibe --vibe-mcp"
  elif [ "$skill_installed" -eq 0 ]; then
    print_field "Mistral Vibe Lean skill" "$installer_cmd --vibe"
  elif [ "$mcp_registered" -eq 0 ]; then
    print_field "Mistral Vibe MCP" "$installer_cmd --vibe-mcp"
  fi
}

print_opencode_followup_hint() {
  local skill_installed="$1"
  local mcp_ready="$2"
  if [ "$skill_installed" -eq 0 ] && [ "$mcp_ready" -eq 0 ]; then
    print_field "OpenCode setup" "$installer_cmd --opencode --opencode-mcp"
  elif [ "$skill_installed" -eq 0 ]; then
    print_field "OpenCode Lean skill" "$installer_cmd --opencode"
  elif [ "$mcp_ready" -eq 0 ]; then
    print_field "OpenCode MCP" "$installer_cmd --opencode-mcp"
  fi
}

print_install_references() {
  print_field "Lean Beam help" "$bin_home/lean-beam help"
  print_field "MCP help" "$bin_home/lean-beam-mcp --help"
  print_field "setup guide" "$repo_root/docs/SETUP.md"
  print_field "workflow guide" "$repo_root/skills/lean-beam/SKILL.md"
  print_field "Rocq guide" "$repo_root/docs/ROCQ.md"
}

print_agent_setup_summary() {
  local codex_skill_installed=0
  local claude_skill_installed=0
  local pi_skill_installed=0
  local opencode_skill_installed=0
  local vibe_skill_installed=0
  local codex_mcp_registered=0
  local claude_mcp_registered=0
  local opencode_mcp_manual=0
  local vibe_mcp_registered=0

  if target_list_contains_prefix "Codex" ${installed_skill_targets[@]+"${installed_skill_targets[@]}"}; then
    codex_skill_installed=1
  fi
  if target_list_contains_prefix "Claude Code" ${installed_skill_targets[@]+"${installed_skill_targets[@]}"}; then
    claude_skill_installed=1
  fi
  if target_list_contains_prefix "Pi Agent" ${installed_skill_targets[@]+"${installed_skill_targets[@]}"}; then
    pi_skill_installed=1
  fi
  if target_list_contains_prefix "OpenCode" ${installed_skill_targets[@]+"${installed_skill_targets[@]}"}; then
    opencode_skill_installed=1
  fi
  if target_list_contains_prefix "Mistral Vibe" ${installed_skill_targets[@]+"${installed_skill_targets[@]}"}; then
    vibe_skill_installed=1
  fi
  if target_list_contains_prefix "Codex" ${registered_mcp_targets[@]+"${registered_mcp_targets[@]}"}; then
    codex_mcp_registered=1
  fi
  if target_list_contains_prefix "Claude Code" ${registered_mcp_targets[@]+"${registered_mcp_targets[@]}"}; then
    claude_mcp_registered=1
  fi
  if target_list_contains_prefix "OpenCode" ${manual_mcp_targets[@]+"${manual_mcp_targets[@]}"}; then
    opencode_mcp_manual=1
  fi
  if target_list_contains_prefix "Mistral Vibe" ${registered_mcp_targets[@]+"${registered_mcp_targets[@]}"}; then
    vibe_mcp_registered=1
  fi

  print_section "$style_green" "Agent Setup"
  print_field "Codex" "skills: $(skill_state_for_summary "$codex_skill_installed"); MCP: $(mcp_state_for_summary "$codex_mcp_registered")"
  print_field "Claude Code" "skills: $(skill_state_for_summary "$claude_skill_installed"); MCP: $(mcp_state_for_summary "$claude_mcp_registered")"
  print_field "Pi Agent" "skills: $(skill_state_for_summary "$pi_skill_installed"); MCP: unsupported"
  if [ "$opencode_mcp_manual" -eq 1 ]; then
    print_field "OpenCode" "skills: $(skill_state_for_summary "$opencode_skill_installed"); MCP: opencode mcp add shown"
  else
    print_field "OpenCode" "skills: $(skill_state_for_summary "$opencode_skill_installed"); MCP: not registered"
  fi
  print_field "Mistral Vibe" "skills: $(skill_state_for_summary "$vibe_skill_installed"); MCP: $(mcp_state_for_summary "$vibe_mcp_registered")"
  print_field "MCP restart" "restart active MCP client sessions to use this runtime"
  print_codex_followup_hint "$codex_skill_installed" "$codex_mcp_registered"
  print_claude_followup_hint "$claude_skill_installed" "$claude_mcp_registered"
  print_pi_followup_hint "$pi_skill_installed"
  print_opencode_followup_hint "$opencode_skill_installed" "$opencode_mcp_manual"
  print_vibe_followup_hint "$vibe_skill_installed" "$vibe_mcp_registered"
  if [ "$codex_skill_installed" -eq 0 ] && [ "$codex_mcp_registered" -eq 0 ] \
    && [ "$claude_skill_installed" -eq 0 ] && [ "$claude_mcp_registered" -eq 0 ] \
    && [ "$pi_skill_installed" -eq 0 ] \
    && [ "$opencode_skill_installed" -eq 0 ] && [ "$opencode_mcp_manual" -eq 0 ] \
    && [ "$vibe_skill_installed" -eq 0 ] && [ "$vibe_mcp_registered" -eq 0 ]; then
    print_field "all agents" "$installer_cmd --all-skills --all-mcp"
  fi
  print_install_references
}

print_manual_mcp_steps() {
  if target_list_contains_prefix "OpenCode" ${manual_mcp_targets[@]+"${manual_mcp_targets[@]}"}; then
    print_section "$style_yellow" "Manual Step Required: OpenCode MCP"
    print_field "run" "opencode mcp add"
    print_field "name" "lean-beam"
    print_field "type" "local"
    print_field "command" "$bin_home/lean-beam-mcp"
  fi
}

print_install_summary() {
  print_section "$style_green" "Install Complete"
  print_field "commands" "$bin_home/{lean-beam,lean-beam-search,lean-beam-mcp}"
  print_field "runtime" "$current_root"
  print_prebuilt_toolchain_summary "$@"
  print_field "shell PATH" "$(install_path_status)"
  print_agent_setup_summary
  print_manual_mcp_steps
}

main() {
  local staging_root=""
  setup_styles
  parse_args "$@"
  validate_install_config
  prepare_install_environment

  confirm_path_edit "create Beam staging directory" "$install_root/.staging-XXXXXX"
  staging_root="$(mktemp -d "$install_root/.staging-XXXXXX")"
  trap 'remove_owned_staging_dir "$staging_root"; release_install_lock' EXIT
  prepare_install_version "$staging_root"
  staging_root=""
  trap 'release_install_lock' EXIT

  prebuild_install_bundles "$prepared_version_root" ${prepared_selected_toolchains[@]+"${prepared_selected_toolchains[@]}"}
  publish_runtime "$prepared_version_root"
  register_requested_mcp_servers
  install_requested_skills
  print_install_summary ${prepared_selected_toolchains[@]+"${prepared_selected_toolchains[@]}"}
  release_install_lock
  trap - EXIT
}

main "$@"
