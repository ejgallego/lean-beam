#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
codex_skills_home="${CODEX_HOME:-$HOME/.codex}/skills"
claude_skills_home="${CLAUDE_HOME:-$HOME/.claude}/skills"
bin_home="${HOME}/.local/bin"
install_root="${RUNAT_INSTALL_ROOT:-$HOME/.local/share/runat}"
versions_root="$install_root/versions"
current_root="$install_root/current"
state_root="$install_root/state"
install_bundles_root="$state_root/install-bundles"
runat_cli="$repo_root/.lake/build/bin/runAt-cli"

runtime_root_files=(
  "RunAt.lean"
  "RunAtCli.lean"
  "lakefile.lean"
  "lakefile.toml"
  "lake-manifest.json"
  "lean-toolchain"
)

runtime_source_dirs=(
  "RunAt"
  "RunAtCli"
  "ffi"
)

runtime_build_paths=(
  ".lake/build/bin/runAt-cli"
  ".lake/build/bin/runAt-cli-daemon"
  ".lake/build/bin/runAt-cli-client"
  ".lake/build/lib/librunAt_RunAt.so"
  ".lake/packages"
)

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
  if [ -x "$runat_cli" ] \
    && [ -x "$repo_root/.lake/build/bin/runAt-cli-daemon" ] \
    && [ -x "$repo_root/.lake/build/bin/runAt-cli-client" ] \
    && [ -f "$repo_root/.lake/build/lib/librunAt_RunAt.so" ]; then
    return 0
  fi
  echo "building runAt runtime artifacts" >&2
  (
    cd "$repo_root"
    lake build RunAt:shared runAt-cli runAt-cli-daemon runAt-cli-client
  )
}

copy_if_present() {
  local src="$1"
  local dest="$2"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
  fi
}

stage_runtime_tree() {
  local dest="$1"
  local path=""
  mkdir -p "$dest"
  for path in "${runtime_root_files[@]}"; do
    copy_if_present "$repo_root/$path" "$dest/$path"
  done
  for path in "${runtime_source_dirs[@]}"; do
    copy_if_present "$repo_root/$path" "$dest/$path"
  done
  for path in "${runtime_build_paths[@]}"; do
    copy_if_present "$repo_root/$path" "$dest/$path"
  done
}

write_runat_wrapper() {
  local dest="$1"
  local default_home="$2"
  local default_install_bundles="$3"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail

default_runat_home="$default_home"
default_install_bundle_dir="$default_install_bundles"
runat_home="\${RUNAT_HOME:-\$default_runat_home}"
runat_install_bundle_dir="\${RUNAT_INSTALL_BUNDLE_DIR:-\$default_install_bundle_dir}"
runat_bin="\$runat_home/.lake/build/bin/runAt-cli"

if [ ! -x "\$runat_bin" ]; then
  echo "missing runAt CLI at \$runat_bin" >&2
  exit 1
fi

export RUNAT_HOME="\$runat_home"
export RUNAT_INSTALL_BUNDLE_DIR="\$runat_install_bundle_dir"
exec "\$runat_bin" "\$@"
EOF
  chmod +x "$dest"
}

write_search_helper() {
  local dest="$1"
  local default_home="$2"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail

default_runat_home="$default_home"
runat_home="\${RUNAT_HOME:-\$default_runat_home}"
runat_script="\$runat_home/bin/runat"

usage() {
  cat <<'USAGE' >&2
usage:
  runat-lean-search [runat opts...] mint <path> <line> <character> <text...>
  runat-lean-search [runat opts...] branch <path> <text...>
  runat-lean-search [runat opts...] linear <path> <text...>
  runat-lean-search [runat opts...] playout <path> <step> [step...]
  runat-lean-search [runat opts...] release <path>

notes:
  - branch, linear, playout, and release read a prior wrapper response or handle JSON from stdin
  - runat opts such as --root and --port may appear before the subcommand
USAGE
  exit 1
}

if [ ! -x "\$runat_script" ]; then
  echo "missing runat wrapper at \$runat_script" >&2
  exit 1
fi

runat_prefix=()
subcmd=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    mint|branch|linear|playout|release)
      subcmd="\$1"
      shift
      break
      ;;
    *)
      runat_prefix+=("\$1")
      shift
      ;;
  esac
done

[ -n "\$subcmd" ] || usage

case "\$subcmd" in
  mint)
    [ "\$#" -ge 4 ] || usage
    path="\$1"
    line="\$2"
    character="\$3"
    shift 3
    exec "\$runat_script" "\${runat_prefix[@]}" lean-run-at-handle "\$path" "\$line" "\$character" "\$@"
    ;;
  branch)
    [ "\$#" -ge 2 ] || usage
    path="\$1"
    shift
    exec "\$runat_script" "\${runat_prefix[@]}" lean-run-with "\$path" - "\$@"
    ;;
  linear)
    [ "\$#" -ge 2 ] || usage
    path="\$1"
    shift
    exec "\$runat_script" "\${runat_prefix[@]}" lean-run-with-linear "\$path" - "\$@"
    ;;
  release)
    [ "\$#" -eq 1 ] || usage
    path="\$1"
    exec "\$runat_script" "\${runat_prefix[@]}" lean-release "\$path" -
    ;;
  playout)
    [ "\$#" -ge 2 ] || usage
    path="\$1"
    shift
    current="\$(cat)"
    for step in "\$@"; do
      current="\$(printf '%s\n' "\$current" | "\$runat_script" "\${runat_prefix[@]}" lean-run-with-linear "\$path" - "\$step")"
    done
    printf '%s\n' "\$current"
    ;;
esac
EOF
  chmod +x "$dest"
}

stage_install_version() {
  local dest="$1"
  local default_home="$2"
  local default_install_bundles="$3"
  stage_runtime_tree "$dest"
  mkdir -p "$dest/bin"
  write_runat_wrapper "$dest/bin/runat" "$default_home" "$default_install_bundles"
  write_search_helper "$dest/bin/runat-lean-search" "$default_home"
}

prebuild_bundle() {
  local runtime_home="$1"
  local toolchain="$2"
  local bundle_home="$3"
  mkdir -p "$bundle_home"
  RUNAT_HOME="$runtime_home" RUNAT_INSTALL_BUNDLE_DIR="$bundle_home" \
    "$runtime_home/.lake/build/bin/runAt-cli" bundle-install "$toolchain"
}

install_skills() {
  local skills_home="$1"
  mkdir -p "$skills_home/lean-runat" "$skills_home/rocq-runat"
  rsync -a "$repo_root/skills/lean-runat/" "$skills_home/lean-runat/"
  rsync -a "$repo_root/skills/rocq-runat/" "$skills_home/rocq-runat/"
}

mkdir -p "$bin_home" "$versions_root" "$state_root"
install_skills "$codex_skills_home"
install_skills "$claude_skills_home"
ensure_runtime_artifacts

staging_root="$(mktemp -d "$install_root/.staging-XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
stage_install_version "$staging_root" "$current_root" "$install_bundles_root"
payload_id="$(hash_tree "$staging_root")"
version_root="$versions_root/$payload_id"
if [ ! -d "$version_root" ]; then
  mv "$staging_root" "$version_root"
else
  rm -rf "$staging_root"
fi
trap - EXIT

if command -v elan >/dev/null 2>&1; then
  repo_toolchain="$(awk 'NR==1 {print $1}' "$repo_root/lean-toolchain")"
  if [ -n "$repo_toolchain" ]; then
    echo "prebuilding runAt bundle for $repo_toolchain" >&2
    prebuild_bundle "$version_root" "$repo_toolchain" "$install_bundles_root"
  else
    echo "warning: could not determine repo lean-toolchain; skipping bundle prebuild" >&2
  fi
else
  echo "warning: elan not found on PATH; skipping bundle prebuild" >&2
fi

ln -sfn "$version_root" "$current_root"
ln -sfn "$current_root/bin/runat" "$bin_home/runat"
ln -sfn "$current_root/bin/runat-lean-search" "$bin_home/runat-lean-search"

cat >&2 <<'EOF'
installed runAt wrapper and skills

human workflow:
  runat ensure lean
  runat lean-run-at "Foo.lean" 10 2 "exact trivial"
  # after a real edit saved to disk
  runat lean-sync "Foo.lean"
  # for a synced workspace module
  runat lean-save "MyPkg/Sub/Module.lean"
  # separate lean-run-at calls do not chain; for exact continuation use:
  runat lean-run-at-handle "Foo.lean" 10 2 "constructor"

diagnostics:
  lean-sync / lean-save / lean-close-save stream errors by default
  add +full to include warnings, info, and hints
  wrapper stderr is human-facing
  runAt-cli-client request-stream is the machine-readable surface

docs:
  see skills/lean-runat/SKILL.md for the Lean workflow contract
EOF
