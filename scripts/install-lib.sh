#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# shellcheck disable=SC2034
# Style variables are assigned here and read by scripts/install-beam.sh after sourcing this file.

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

die() {
  echo "$*" >&2
  exit 1
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

path_is_within() {
  local path="$1"
  local root="$2"
  case "$path" in
    "$root"|"$root"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_path_within() {
  local path="$1"
  local root="$2"
  local label="$3"
  require_absolute_path "$path" "$label"
  require_absolute_path "$root" "$label root"
  if ! path_is_within "$path" "$root"; then
    die "refusing to use $label outside $root: $path"
  fi
}

require_not_root() {
  local path="$1"
  local label="$2"
  if [ "$path" = "/" ]; then
    die "refusing to use / as $label"
  fi
}

hash_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
  elif command -v shasum >/dev/null 2>&1; then
    printf 'shasum\n'
  else
    die "missing sha256sum or shasum for install payload hashing"
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

normalize_choice() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

prompt_agent_target_multi_choice() {
  local title="$1"
  local intro="$2"
  local prompt="$3"
  local error_context="$4"
  shift 4
  local entries=("$@")
  local reply=""
  local normalized_reply=""
  local token=""
  local entry=""
  local key=""
  local label=""
  local aliases=""
  local alias=""
  local ordinal=2
  local all_ordinal=$(( ${#entries[@]} + 2 ))
  local selected=()
  local select_all=0
  local matched=0

  print_section "$style_blue" "$title"
  printf '%s\n' "$intro" >&2
  printf '  1) none (default)\n' >&2
  for entry in ${entries[@]+"${entries[@]}"}; do
    IFS='|' read -r key label aliases <<< "$entry"
    printf '  %d) %s\n' "$ordinal" "$label" >&2
    ordinal=$((ordinal + 1))
  done
  printf '  %d) all\n' "$all_ordinal" >&2
  printf '%s [Enter: none; comma-separated selections allowed]: ' "$prompt" >&2
  IFS= read -r reply || reply=""
  normalized_reply="$(normalize_choice "$reply")"
  normalized_reply="${normalized_reply//,/ }"

  if [ -z "$normalized_reply" ]; then
    printf 'none\n'
    return 0
  fi

  for token in $normalized_reply; do
    case "$token" in
      ""|1|n|no|none)
        if [ "${#selected[@]}" -gt 0 ] || [ "$select_all" -eq 1 ]; then
          die "cannot combine none with other $error_context selections"
        fi
        printf 'none\n'
        return 0
        ;;
      all|a)
        select_all=1
        continue
        ;;
    esac

    if [ "$token" = "$all_ordinal" ]; then
      select_all=1
      continue
    fi

    matched=0
    ordinal=2
    for entry in ${entries[@]+"${entries[@]}"}; do
      IFS='|' read -r key label aliases <<< "$entry"
      if [ "$token" = "$ordinal" ] || [ "$token" = "$key" ]; then
        if ! array_contains "$key" ${selected[@]+"${selected[@]}"}; then
          selected+=("$key")
        fi
        matched=1
        break
      fi
      for alias in $aliases; do
        if [ "$token" = "$alias" ]; then
          if ! array_contains "$key" ${selected[@]+"${selected[@]}"}; then
            selected+=("$key")
          fi
          matched=1
          break
        fi
      done
      if [ "$matched" -eq 1 ]; then
        break
      fi
      ordinal=$((ordinal + 1))
    done
    if [ "$matched" -eq 0 ]; then
      die "unknown $error_context selection: $token"
    fi
  done

  if [ "$select_all" -eq 1 ]; then
    selected=()
    for entry in ${entries[@]+"${entries[@]}"}; do
      IFS='|' read -r key label aliases <<< "$entry"
      selected+=("$key")
    done
  fi

  if [ "${#selected[@]}" -eq 0 ]; then
    printf 'none\n'
  else
    printf '%s\n' "${selected[*]}"
  fi
}
