#!/usr/bin/env python3

import argparse
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path


CHILD_CODE = r"""
import argparse
import ctypes
import faulthandler
import http.server
import os
import platform
import signal
import socket
import subprocess
import sys
import sysconfig
import threading
import time


def log(message, **fields):
    suffix = ""
    if fields:
        suffix = " " + " ".join(f"{key}={value!r}" for key, value in fields.items())
    print(f"mcp-http-python-getfqdn-probe child: {message}{suffix}", flush=True)


def drain_pipe(pipe):
    for _line in pipe:
        pass


parser = argparse.ArgumentParser()
parser.add_argument(
    "--mode",
    choices=(
        "python-gethostbyaddr",
        "ctypes-gethostbyaddr",
        "direct",
        "threaded-child",
        "raw-bound-getfqdn",
        "http-server",
    ),
    required=True,
)
args = parser.parse_args()

faulthandler.enable(all_threads=True)
if hasattr(signal, "SIGUSR1"):
    faulthandler.register(signal.SIGUSR1, all_threads=True)

resolver_config_keys = [
    "HAVE_GETHOSTBYNAME_R",
    "HAVE_GETHOSTBYNAME_R_3_ARG",
    "HAVE_GETHOSTBYNAME_R_5_ARG",
    "HAVE_GETHOSTBYNAME_R_6_ARG",
    "HAVE_GETHOSTBYADDR",
    "HAVE_GETADDRINFO",
]
resolver_config = {key: sysconfig.get_config_var(key) for key in resolver_config_keys}

log(
    "starting",
    pid=os.getpid(),
    mode=args.mode,
    python=sys.version.split()[0],
    platform=platform.platform(),
    cpu_count=os.cpu_count(),
    resolver_config=resolver_config,
)

helper = None
if args.mode == "threaded-child":
    helper = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(300)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    thread = threading.Thread(target=drain_pipe, args=(helper.stderr,), daemon=True)
    thread.start()
    log("started helper child and stderr drain", helper_pid=helper.pid)

class ProbeHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass


def ctypes_gethostbyaddr(host):
    packed = socket.inet_aton(host)
    buffer = ctypes.create_string_buffer(packed, len(packed))
    libc = ctypes.CDLL(None)
    gethostbyaddr = libc.gethostbyaddr
    gethostbyaddr.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    gethostbyaddr.restype = ctypes.c_void_p
    return gethostbyaddr(buffer, len(packed), socket.AF_INET)


start = time.monotonic()
try:
    if args.mode == "http-server":
        log("HTTPServer construction starting", address=("127.0.0.1", 0))
        server = http.server.HTTPServer(("127.0.0.1", 0), ProbeHandler)
        try:
            result = server.server_name
            log(
                "HTTPServer construction complete",
                elapsed=f"{time.monotonic() - start:.3f}s",
                server_name=server.server_name,
                server_port=server.server_port,
                sockname=server.socket.getsockname(),
            )
        finally:
            server.server_close()
    elif args.mode == "python-gethostbyaddr":
        log("socket.gethostbyaddr starting", host="127.0.0.1")
        result = socket.gethostbyaddr("127.0.0.1")
        log(
            "socket.gethostbyaddr complete",
            host="127.0.0.1",
            elapsed=f"{time.monotonic() - start:.3f}s",
            result=result,
        )
    elif args.mode == "ctypes-gethostbyaddr":
        log("ctypes gethostbyaddr starting", host="127.0.0.1")
        result = ctypes_gethostbyaddr("127.0.0.1")
        log(
            "ctypes gethostbyaddr complete",
            host="127.0.0.1",
            elapsed=f"{time.monotonic() - start:.3f}s",
            result=bool(result),
        )
    else:
        bound_socket = None
        if args.mode == "raw-bound-getfqdn":
            bound_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            bound_socket.bind(("127.0.0.1", 0))
            log("raw socket bound before getfqdn", sockname=bound_socket.getsockname())
        log("getfqdn starting", host="127.0.0.1")
        try:
            result = socket.getfqdn("127.0.0.1")
        finally:
            if bound_socket is not None:
                bound_socket.close()
        log("getfqdn complete", host="127.0.0.1", elapsed=f"{time.monotonic() - start:.3f}s", result=result)
finally:
    if helper is not None:
        helper.terminate()
        try:
            helper.wait(timeout=5)
        except subprocess.TimeoutExpired:
            helper.kill()
            helper.wait(timeout=5)
"""


MINIMAL_CHILD_CODE = r"""
import argparse
import ctypes
import faulthandler
import os
import platform
import signal
import socket
import sys
import time


def log(message, **fields):
    suffix = ""
    if fields:
        suffix = " " + " ".join(f"{key}={value!r}" for key, value in fields.items())
    print(f"mcp-http-python-getfqdn-probe minimal child: {message}{suffix}", flush=True)


def ctypes_gethostbyaddr(host):
    packed = socket.inet_aton(host)
    buffer = ctypes.create_string_buffer(packed, len(packed))
    libc = ctypes.CDLL(None)
    gethostbyaddr = libc.gethostbyaddr
    gethostbyaddr.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    gethostbyaddr.restype = ctypes.c_void_p
    return gethostbyaddr(buffer, len(packed), socket.AF_INET)


parser = argparse.ArgumentParser()
parser.add_argument(
    "--mode",
    choices=(
        "minimal-gethostbyaddr",
        "minimal-ctypes-gethostbyaddr",
        "minimal-getfqdn",
    ),
    required=True,
)
args = parser.parse_args()

faulthandler.enable(all_threads=True)
if hasattr(signal, "SIGUSR1"):
    faulthandler.register(signal.SIGUSR1, all_threads=True)

log(
    "starting",
    pid=os.getpid(),
    mode=args.mode,
    python=sys.version.split()[0],
    platform=platform.platform(),
    cpu_count=os.cpu_count(),
)

start = time.monotonic()
if args.mode == "minimal-gethostbyaddr":
    log("socket.gethostbyaddr starting", host="127.0.0.1")
    result = socket.gethostbyaddr("127.0.0.1")
    log(
        "socket.gethostbyaddr complete",
        host="127.0.0.1",
        elapsed=f"{time.monotonic() - start:.3f}s",
        result=result,
    )
elif args.mode == "minimal-ctypes-gethostbyaddr":
    log("ctypes gethostbyaddr starting", host="127.0.0.1")
    result = ctypes_gethostbyaddr("127.0.0.1")
    log(
        "ctypes gethostbyaddr complete",
        host="127.0.0.1",
        elapsed=f"{time.monotonic() - start:.3f}s",
        result=bool(result),
    )
else:
    log("getfqdn starting", host="127.0.0.1")
    result = socket.getfqdn("127.0.0.1")
    log("getfqdn complete", host="127.0.0.1", elapsed=f"{time.monotonic() - start:.3f}s", result=result)
"""


FULL_MODES = [
    "python-gethostbyaddr",
    "ctypes-gethostbyaddr",
    "direct",
    "threaded-child",
    "raw-bound-getfqdn",
    "http-server",
]

MINIMAL_MODES = [
    "minimal-gethostbyaddr",
    "minimal-ctypes-gethostbyaddr",
    "minimal-getfqdn",
]

ALL_MODES = MINIMAL_MODES + FULL_MODES


def log(message, **fields):
    suffix = ""
    if fields:
        suffix = " " + " ".join(f"{key}={json.dumps(value, default=str)}" for key, value in fields.items())
    print(f"mcp-http-python-getfqdn-probe: {message}{suffix}", file=sys.stderr, flush=True)


def print_text_section(title, text, *, max_lines=240, head_lines=None, tail_lines=None):
    print(f"--- {title} ---", file=sys.stderr)
    if not text:
        print("<empty>", file=sys.stderr)
        return
    lines = text.rstrip("\n").splitlines()
    if len(lines) > max_lines:
        if head_lines is None and tail_lines is None:
            head_lines = max_lines // 2
            tail_lines = max_lines - head_lines
        elif head_lines is None:
            head_lines = max_lines - tail_lines
        elif tail_lines is None:
            tail_lines = max_lines - head_lines
        omitted = len(lines) - head_lines - tail_lines
        lines = (
            lines[:head_lines]
            + [f"<omitting {omitted} middle lines>"]
            + lines[-tail_lines:]
        )
    for line in lines:
        print(line, file=sys.stderr)


def sample_process(pid, duration, output_dir):
    if platform.system() != "Darwin":
        log("sample unavailable on non-Darwin platform", pid=pid)
        return
    sample = shutil.which("sample")
    if sample is None:
        log("sample command unavailable", pid=pid)
        return
    sample_file = output_dir / f"python-getfqdn-sample-{pid}.txt"
    log("running macOS sample", pid=pid, duration=duration, output=str(sample_file))
    try:
        result = subprocess.run(
            [sample, str(pid), str(duration), "-file", str(sample_file)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            timeout=duration + 10,
            check=False,
        )
    except Exception as err:
        log("sample command failed to run", pid=pid, error=str(err))
        return
    if result.stdout:
        print_text_section("sample stdout", result.stdout)
    if result.stderr:
        print_text_section("sample stderr", result.stderr)
    if sample_file.exists():
        print_text_section(
            "sample output",
            sample_file.read_text(encoding="utf-8", errors="replace"),
            max_lines=420,
            head_lines=320,
            tail_lines=100,
        )
    else:
        log("sample output missing", pid=pid, returncode=result.returncode)


def run_mode(mode, timeout, sample_duration):
    log(
        "parent starting child",
        mode=mode,
        timeout=timeout,
        python=sys.version.split()[0],
        platform=platform.platform(),
        cpu_count=os.cpu_count(),
    )
    with tempfile.TemporaryDirectory(prefix="lean-beam-python-getfqdn-") as tmp:
        output_dir = Path(tmp)
        child_code = MINIMAL_CHILD_CODE if mode in MINIMAL_MODES else CHILD_CODE
        proc = subprocess.Popen(
            [sys.executable, "-c", child_code, "--mode", mode],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            log("child timed out", mode=mode, pid=proc.pid, timeout=timeout)
            if hasattr(signal, "SIGUSR1"):
                try:
                    os.kill(proc.pid, signal.SIGUSR1)
                    time.sleep(1)
                except ProcessLookupError:
                    pass
                except Exception as err:
                    log("failed to trigger faulthandler", mode=mode, pid=proc.pid, error=str(err))
            sample_process(proc.pid, sample_duration, output_dir)
            proc.kill()
            stdout, stderr = proc.communicate(timeout=5)
            print_text_section(f"{mode} child stdout", stdout)
            print_text_section(f"{mode} child stderr", stderr)
            return 124
        print_text_section(f"{mode} child stdout", stdout)
        if stderr:
            print_text_section(f"{mode} child stderr", stderr)
        log("child completed", mode=mode, returncode=proc.returncode)
        return proc.returncode


def main():
    parser = argparse.ArgumentParser(
        description="Probe Python socket.getfqdn('127.0.0.1') with timeout diagnostics."
    )
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--sample-duration", type=int, default=2)
    parser.add_argument(
        "--mode",
        action="append",
        choices=ALL_MODES,
        default=[],
        help="Probe mode to run. Defaults to all modes.",
    )
    args = parser.parse_args()
    modes = args.mode or ALL_MODES
    rc = 0
    for mode in modes:
        rc = max(rc, run_mode(mode, args.timeout, args.sample_duration))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
