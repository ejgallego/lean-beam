#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_root/scripts/shared-lib.sh"
codex_skills_home="${CODEX_HOME:-$HOME/.codex}/skills"
claude_skills_home="${CLAUDE_HOME:-$HOME/.claude}/skills"
bin_home="${HOME}/.local/bin"
install_root="${BEAM_INSTALL_ROOT:-$HOME/.local/share/beam}"
versions_root="$install_root/versions"
current_root="$install_root/current"
state_root="$install_root/state"
install_bundles_root="$state_root/install-bundles"
beam_cli="$repo_root/.lake/build/bin/beam-cli"
install_notes_path="$repo_root/scripts/install-beam-notes.txt"
installer_cmd="./scripts/install-beam.sh"
install_codex_skills=0
install_claude_skills=0
install_all_supported=0
dont_ask=0
requested_toolchains=()
installed_skill_targets=()
prepared_repo_toolchain=""
prepared_selected_toolchains=()
prepared_payload_id=""
prepared_version_root=""
prepared_source_commit=""
style_reset=""
style_bold=""
style_green=""
style_blue=""
style_yellow=""
style_dim=""
runat_plugin_shared_lib="$(beam_shared_lib_name runAt_RunAt)"
install_root_marker=".lean-beam-install-root"
skill_owner_marker=".lean-beam-skill"
install_lock_dir="$install_root/.install-lock"

runtime_payload_spec=(
  "copy|rootFiles|RunAt.lean|RunAt.lean"
  "copy|rootFiles|Beam.lean|Beam.lean"
  "copy|rootFiles|lakefile.lean|lakefile.lean"
  "copy|rootFiles|lakefile.toml|lakefile.toml"
  "copy|rootFiles|lake-manifest.json|lake-manifest.json"
  "copy|rootFiles|lean-toolchain|lean-toolchain"
  "copy|rootFiles|supported-lean-toolchains|supported-lean-toolchains"
  "copy|sourceDirs|RunAt|RunAt"
  "copy|sourceDirs|Beam|Beam"
  "copy|sourceDirs|ffi|ffi"
  "copy|runtimePaths|.lake/build/bin/beam-cli|libexec/beam-cli"
  "copy|runtimePaths|.lake/build/bin/beam-daemon|libexec/beam-daemon"
  "copy|runtimePaths|.lake/build/bin/beam-client|libexec/beam-client"
  "copy|runtimePaths|.lake/build/bin/lean-beam-mcp|libexec/lean-beam-mcp"
  "copy|runtimePaths|.lake/build/lib/$runat_plugin_shared_lib|libexec/$runat_plugin_shared_lib"
  "copy|runtimePaths|.lake/packages|.lake/packages"
  "copy|wrapperPaths|scripts/lean-beam|bin/lean-beam"
  "copy|wrapperPaths|scripts/lean-beam-search|bin/lean-beam-search"
  "copy|wrapperPaths|scripts/lean-beam-mcp|bin/lean-beam-mcp"
)

usage() {
  cat <<EOF
Usage:
  $installer_cmd [--toolchain TOOLCHAIN ... | --all-supported] [--codex] [--claude] [--all-skills]

Installs the local beam command wrappers and self-contained runtime under:
  $install_root

With no flags, this installs:
  - $bin_home/lean-beam
  - $bin_home/lean-beam-search
  - $bin_home/lean-beam-mcp
  - one prebuilt toolchain build for the repo-pinned Lean toolchain

With no agent flags, this does not install Codex or Claude Code skills.

Optional flags:
  --dont-ask    do not prompt before Beam-owned filesystem edits
  --don't-ask   alias for --dont-ask
  --yes         alias for --dont-ask
  --toolchain    prebuild one supported Lean toolchain; may be repeated
  --all-supported
                prebuild every supported Lean toolchain
  --codex       install bundled Lean and Rocq skills into $codex_skills_home
  --claude      install bundled Lean and Rocq skills into $claude_skills_home
  --all-skills  install bundled skills for both Codex and Claude Code
  -h, --help    show this help

Environment:
  BEAM_INSTALL_ROOT   override the runtime install root
  CODEX_HOME           override the Codex home used by --codex
  CLAUDE_HOME          override the Claude home used by --claude

Requirements:
  elan must be on PATH so the installer can prebuild the selected Lean bundle(s)
EOF
}

setup_styles() {
  if [ -t 2 ] && [ "${TERM:-}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    style_reset=$'\033[0m'
    style_bold=$'\033[1m'
    style_green=$'\033[32m'
    style_blue=$'\033[34m'
    style_yellow=$'\033[33m'
    style_dim=$'\033[2m'
  fi
}

print_section() {
  local color="$1"
  local title="$2"
  printf '\n%s%s%s%s\n' "$style_bold" "$color" "$title" "$style_reset" >&2
}

print_field() {
  local label="$1"
  local value="$2"
  printf '  %s%-18s%s %s\n' "$style_dim" "$label" "$style_reset" "$value" >&2
}

path_contains_dir() {
  local dir="$1"
  case ":${PATH:-}:" in
    *":$dir:"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

die() {
  echo "$*" >&2
  exit 1
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

require_no_parent_refs() {
  local path="$1"
  local label="$2"
  case "$path" in
    *"/../"*|*/..|../*|..)
      die "$label must not contain '..': $path"
      ;;
  esac
}

require_absolute_path() {
  local path="$1"
  local label="$2"
  if [ -z "$path" ]; then
    die "missing $label"
  fi
  case "$path" in
    /*)
      ;;
    *)
      die "$label must be an absolute path: $path"
      ;;
  esac
  require_no_parent_refs "$path" "$label"
}

require_path_within() {
  local path="$1"
  local root="$2"
  local label="$3"
  require_absolute_path "$path" "$label"
  require_absolute_path "$root" "$label root"
  case "$path" in
    "$root"|"$root"/*)
      ;;
    *)
      die "refusing to use $label outside $root: $path"
      ;;
  esac
}

require_not_root() {
  local path="$1"
  local label="$2"
  if [ "$path" = "/" ]; then
    die "refusing to use / as $label"
  fi
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
  confirm_edit "create $label directory" "$path"
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
  confirm_edit "mark Beam install root as installer-owned" "$marker"
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
  confirm_edit "publish staged runtime version" "$version_dir"
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
  confirm_edit "publish $label" "$link_path -> $target"
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
        requested_toolchains+=("$2")
        shift
        ;;
      --all-supported)
        install_all_supported=1
        ;;
      --codex)
        install_codex_skills=1
        ;;
      --claude)
        install_claude_skills=1
        ;;
      --all-skills)
        install_codex_skills=1
        install_claude_skills=1
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
  require_absolute_path "$install_notes_path" "install notes path"
  require_not_root "$bin_home" "bin home"
  require_not_root "$install_root" "install root"
  require_path_within "$versions_root" "$install_root" "versions root"
  require_path_within "$current_root" "$install_root" "current link"
  require_path_within "$state_root" "$install_root" "state root"
  require_path_within "$install_bundles_root" "$state_root" "install bundle root"
}

hash_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
  elif command -v shasum >/dev/null 2>&1; then
    printf 'shasum\n'
  else
    echo "missing sha256sum or shasum for install payload hashing" >&2
    exit 1
  fi
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

array_contains() {
  local needle="$1"
  shift
  local value=""
  for value in "$@"; do
    if [ "$value" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

resolve_install_toolchains() {
  local repo_toolchain="$1"
  local supported_toolchains=()
  local selected=()
  local toolchain=""

  if [ "$install_all_supported" -eq 1 ] && [ "${#requested_toolchains[@]}" -gt 0 ]; then
    die "cannot combine --all-supported with --toolchain"
  fi

  while IFS= read -r toolchain; do
    [ -n "$toolchain" ] || continue
    supported_toolchains+=("$toolchain")
  done < <(read_supported_toolchains)
  if [ "${#supported_toolchains[@]}" -eq 0 ]; then
    die "beam CLI reported no supported Lean toolchains"
  fi

  if [ "$install_all_supported" -eq 1 ]; then
    selected=("${supported_toolchains[@]}")
  elif [ "${#requested_toolchains[@]}" -gt 0 ]; then
    for toolchain in "${requested_toolchains[@]}"; do
      if ! array_contains "$toolchain" "${supported_toolchains[@]}"; then
        die "unsupported Lean toolchain requested for install: $toolchain"
      fi
      if [ "${#selected[@]}" -eq 0 ] || ! array_contains "$toolchain" "${selected[@]}"; then
        selected+=("$toolchain")
      fi
    done
  else
    if ! array_contains "$repo_toolchain" "${supported_toolchains[@]}"; then
      die "pinned Lean toolchain is not in supported-lean-toolchains: $repo_toolchain"
    fi
    selected=("$repo_toolchain")
  fi

  printf '%s\n' "${selected[@]}"
}

print_install_plan() {
  local resolved_toolchains="$1"
  local toolchain=""
  print_section "$style_blue" "Install Plan"
  print_field "install root" "$install_root"
  print_field "bin directory" "$bin_home"
  print_field "bundle cache" "$install_bundles_root"
  print_field "Codex skills" "$(if [ "$install_codex_skills" -eq 1 ]; then printf '%s' "$codex_skills_home"; else printf 'not requested'; fi)"
  print_field "Claude skills" "$(if [ "$install_claude_skills" -eq 1 ]; then printf '%s' "$claude_skills_home"; else printf 'not requested'; fi)"
  if [ -n "$resolved_toolchains" ]; then
    while IFS= read -r toolchain; do
      [ -n "$toolchain" ] || continue
      print_field "toolchain" "$toolchain"
    done <<< "$resolved_toolchains"
  fi
  if [ "$dont_ask" -eq 0 ]; then
    print_field "approval" "each filesystem edit will ask first"
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
  if [ -x "$beam_cli" ] \
    && [ -x "$repo_root/.lake/build/bin/beam-daemon" ] \
    && [ -x "$repo_root/.lake/build/bin/beam-client" ] \
    && [ -x "$repo_root/.lake/build/bin/lean-beam-mcp" ] \
    && [ -f "$repo_root/.lake/build/lib/$runat_plugin_shared_lib" ]; then
    return 0
  fi
  confirm_edit "build Beam runtime artifacts in the source checkout" "$repo_root/.lake/build"
  echo "building beam runtime artifacts" >&2
  (
    cd "$repo_root"
    lake build RunAt:shared beam-cli beam-daemon beam-client lean-beam-mcp
  )
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
  mkdir -p "$dest"
  for entry in "${runtime_payload_spec[@]}"; do
    IFS='|' read -r mode _ src_rel dest_rel <<< "$entry"
    case "$mode" in
      copy)
        copy_repo_path_if_present "$repo_root/$src_rel" "$dest/$dest_rel" "$dest"
        ;;
      generated)
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
  confirm_edit "prebuild Beam bundle" "$toolchain" "$bundle_home"
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
  confirm_edit "install $label skill" "$target_dir"
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
  install_one_skill "$repo_root/skills/rocq-beam" "$skills_home/rocq-beam" "rocq-beam"
}

install_skill_target() {
  local label="$1"
  local skills_home="$2"
  install_skills "$skills_home"
  printf '%s: %s\n' "$label" "$skills_home"
}

verify_skill_home_targets() {
  local skills_home="$1"
  require_absolute_path "$skills_home" "skills home"
  ensure_skill_target_replaceable "$skills_home/lean-beam" "lean-beam"
  ensure_skill_target_replaceable "$skills_home/rocq-beam" "rocq-beam"
}

verify_requested_skill_targets() {
  if [ "$install_codex_skills" -eq 1 ]; then
    verify_skill_home_targets "$codex_skills_home"
  fi
  if [ "$install_claude_skills" -eq 1 ]; then
    verify_skill_home_targets "$claude_skills_home"
  fi
}

prepare_install_environment() {
  local resolved_toolchains=""
  local toolchain=""
  require_elan
  prepared_repo_toolchain="$(awk 'NR==1 {print $1}' "$repo_root/lean-toolchain")"
  require_repo_toolchain "$prepared_repo_toolchain"
  resolved_toolchains="$(resolve_install_toolchains "$prepared_repo_toolchain")"
  print_install_plan "$resolved_toolchains"
  verify_requested_skill_targets
  ensure_install_root_ready
  acquire_install_lock
  ensure_runtime_artifacts
  prepared_selected_toolchains=()
  if [ -n "$resolved_toolchains" ]; then
    while IFS= read -r toolchain; do
      [ -n "$toolchain" ] || continue
      prepared_selected_toolchains+=("$toolchain")
    done <<< "$resolved_toolchains"
  fi
  verify_publish_targets
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
    "${prepared_selected_toolchains[@]}"
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
      "${prepared_selected_toolchains[@]}"
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
}

print_install_summary() {
  local version_root="$1"
  shift
  local toolchain=""
  local codex_status="not installed"
  local claude_status="not installed"
  local path_status="$bin_home is not on PATH yet"

  if path_contains_dir "$bin_home"; then
    path_status="ready for direct \`lean-beam\` and \`lean-beam-mcp\` use in this shell"
  fi
  if [ -n "${installed_skill_targets[*]-}" ]; then
    for toolchain in "${installed_skill_targets[@]}"; do
      case "$toolchain" in
        Codex:*)
          codex_status="installed at ${toolchain#Codex: }"
          ;;
        "Claude Code:"*)
          claude_status="installed at ${toolchain#Claude Code: }"
          ;;
      esac
    done
  fi

  print_section "$style_green" "Install Complete"
  print_field "lean-beam" "$bin_home/lean-beam"
  print_field "lean search helper" "$bin_home/lean-beam-search"
  print_field "MCP server" "$bin_home/lean-beam-mcp"
  print_field "active install" "$current_root"
  print_field "versioned install" "$version_root"
  print_field "Lean toolchain store" "$install_bundles_root"
  if [ "$#" -gt 0 ]; then
    print_field "prebuilt toolchains" "$1"
    shift
    for toolchain in "$@"; do
      printf '  %s%-18s%s %s\n' "$style_dim" "" "$style_reset" "$toolchain" >&2
    done
  else
    print_field "prebuilt toolchains" "none"
  fi
  print_field "shell PATH" "$path_status"

  print_section "$style_blue" "Agent Skills"
  print_field "Codex skill" "$codex_status"
  print_field "Claude skill" "$claude_status"
  if [ "$codex_status" = "not installed" ] && [ "$claude_status" = "not installed" ]; then
    print_field "note" "the base install does not add agent skills unless you request them"
  fi

  print_section "$style_yellow" "Optional Next Steps"
  if [ "$codex_status" = "not installed" ]; then
    print_field "Codex" "$installer_cmd --codex"
  fi
  if [ "$claude_status" = "not installed" ]; then
    print_field "Claude Code" "$installer_cmd --claude"
  fi
  if [ "$codex_status" = "not installed" ] || [ "$claude_status" = "not installed" ]; then
    print_field "both skills" "$installer_cmd --all-skills"
  fi
}

print_post_install_notes() {
  print_section "$style_blue" "Try It"
  cat "$install_notes_path" >&2
}

main() {
  local staging_root=""
  setup_styles
  parse_args "$@"
  validate_install_config
  prepare_install_environment

  confirm_edit "create Beam staging directory" "$install_root/.staging-XXXXXX"
  staging_root="$(mktemp -d "$install_root/.staging-XXXXXX")"
  trap 'remove_owned_staging_dir "$staging_root"; release_install_lock' EXIT
  prepare_install_version "$staging_root"
  staging_root=""
  trap 'release_install_lock' EXIT

  prebuild_install_bundles "$prepared_version_root" "${prepared_selected_toolchains[@]}"
  publish_runtime "$prepared_version_root"
  install_requested_skills
  print_install_summary "$prepared_version_root" "${prepared_selected_toolchains[@]}"
  print_post_install_notes
  release_install_lock
  trap - EXIT
}

main "$@"
