#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# Shared helper functions for installer tests. Callers provide the install-test
# globals such as source_checkout, supported_toolchains, and preseed_elan_home.
# shellcheck disable=SC2154

beam_install_setup_mcp_cli_stubs() {
  local stub_bin="$1"
  local log_path="$2"
  mkdir -p "$stub_bin"
  rm -f -- "$log_path"
  cat > "$stub_bin/codex" <<'SH'
#!/usr/bin/env bash
{
  printf 'codex'
  for arg in "$@"; do
    printf '|%s' "$arg"
  done
  printf '|CODEX_HOME=%s' "${CODEX_HOME:-}"
  printf '\n'
} >> "$BEAM_TEST_MCP_STUB_LOG"
exit 0
SH
  cat > "$stub_bin/claude" <<'SH'
#!/usr/bin/env bash
{
  printf 'claude'
  for arg in "$@"; do
    printf '|%s' "$arg"
  done
  printf '|HOME=%s' "${HOME:-}"
  printf '\n'
} >> "$BEAM_TEST_MCP_STUB_LOG"
exit 0
SH
  chmod +x "$stub_bin/codex" "$stub_bin/claude"
}

beam_install_run_with_mcp_stubs() {
  local stub_bin="$1"
  local log_path="$2"
  shift 2
  preseed_elan_home "$HOME/.elan" ${supported_toolchains[@]+"${supported_toolchains[@]}"}
  (
    cd "$source_checkout" || exit
    BEAM_TEST_MCP_STUB_LOG="$log_path" PATH="$stub_bin:$PATH" \
      bash scripts/install-beam.sh --dont-ask "$@" > /dev/null
  )
}

beam_install_run_interactive_from_source() {
  local transcript="$1"
  local install_home="$2"
  local install_root="$3"
  local input_text="$4"
  shift 4
  preseed_elan_home "$install_home/.elan" ${supported_toolchains[@]+"${supported_toolchains[@]}"}
  (
    cd "$source_checkout" || exit
    python3 - "$transcript" "$install_home" "$install_root" "$input_text" "$@" <<'PY'
import errno
import os
import pty
import select
import subprocess
import sys

transcript_path = sys.argv[1]
install_home = sys.argv[2]
install_root = sys.argv[3]
input_text = sys.argv[4]
cmd = ["bash", "scripts/install-beam.sh", *sys.argv[5:]]
env = os.environ.copy()
env["HOME"] = install_home
env["BEAM_INSTALL_ROOT"] = install_root

master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=env)
os.close(slave)
if input_text:
    os.write(master, input_text.encode())

chunks = []
while True:
    ready, _, _ = select.select([master], [], [], 0.1)
    if master in ready:
        try:
            data = os.read(master, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        chunks.append(data)
    if proc.poll() is not None:
        while True:
            try:
                data = os.read(master, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            chunks.append(data)
        break

rc = proc.wait()
os.close(master)
with open(transcript_path, "wb") as f:
    f.write(b"".join(chunks))
sys.exit(rc)
PY
  )
}
