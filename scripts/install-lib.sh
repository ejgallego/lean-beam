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

print_array_lines() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
  fi
}
