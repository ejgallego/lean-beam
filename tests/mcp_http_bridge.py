#!/usr/bin/env python3

import argparse
import json
import select
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse


PROTOCOL_VERSION = "2025-11-25"


class BridgeError(Exception):
    pass


class StdioMcpServer:
    def __init__(self, command, cwd, timeout):
        self.command = command
        self.timeout = timeout
        self.lock = threading.Lock()
        self.stderr = []
        self.proc = subprocess.Popen(
            command,
            cwd=str(cwd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self.stderr_thread.start()

    def _drain_stderr(self):
        for line in self.proc.stderr:
            self.stderr.append(line)

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)

    def send_notification(self, message):
        with self.lock:
            self._write_message(message)

    def send_request(self, message):
        with self.lock:
            self._write_message(message)
            return self._read_response()

    def _write_message(self, message):
        if self.proc.poll() is not None:
            raise BridgeError(f"lean-beam-mcp exited with code {self.proc.returncode}")
        line = json.dumps(message, separators=(",", ":"))
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _read_response(self):
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BridgeError("timed out waiting for lean-beam-mcp response")
            if self.proc.poll() is not None:
                stderr = "".join(self.stderr)
                raise BridgeError(f"lean-beam-mcp exited with code {self.proc.returncode}\n{stderr}")
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if line == "":
                raise BridgeError("lean-beam-mcp closed stdout")
            try:
                return json.loads(line)
            except json.JSONDecodeError as err:
                raise BridgeError(f"lean-beam-mcp wrote invalid JSON: {err}: {line!r}") from err


class BridgeHttpServer(HTTPServer):
    allow_reuse_address = True

    def __init__(self, server_address, handler_cls, *, endpoint, allowed_origins, mcp):
        super().__init__(server_address, handler_cls)
        self.endpoint = endpoint
        self.allowed_origins = allowed_origins
        self.mcp = mcp


class McpBridgeHandler(BaseHTTPRequestHandler):
    server_version = "lean-beam-mcp-http-bridge/0"

    def log_message(self, fmt, *args):
        if self.server.verbose:
            super().log_message(fmt, *args)

    def do_GET(self):
        if not self._check_path():
            return
        self._send_empty(HTTPStatus.METHOD_NOT_ALLOWED)

    def do_DELETE(self):
        if not self._check_path():
            return
        self._send_empty(HTTPStatus.METHOD_NOT_ALLOWED)

    def do_POST(self):
        if not self._check_path():
            return
        if not self._check_origin():
            return
        if not self._check_content_type():
            return
        if not self._check_accept():
            return
        if not self._check_protocol_version_header():
            return

        try:
            body = self._read_json_body()
        except BridgeError as err:
            self._send_json_error(HTTPStatus.BAD_REQUEST, None, -32700, str(err))
            return

        if not isinstance(body, dict):
            self._send_json_error(HTTPStatus.BAD_REQUEST, None, -32600, "HTTP body must be one JSON-RPC object")
            return

        is_request = "id" in body
        try:
            if is_request:
                response = self.server.mcp.send_request(body)
                self._send_json(HTTPStatus.OK, response)
                if body.get("method") == "shutdown":
                    threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self.server.mcp.send_notification(body)
                self._send_empty(HTTPStatus.ACCEPTED)
        except BridgeError as err:
            self._send_json_error(HTTPStatus.INTERNAL_SERVER_ERROR, body.get("id"), -32603, str(err))

    def _check_path(self):
        if urlparse(self.path).path != self.server.endpoint:
            self._send_empty(HTTPStatus.NOT_FOUND)
            return False
        return True

    def _check_origin(self):
        origin = self.headers.get("Origin")
        if origin is not None and origin not in self.server.allowed_origins:
            self._send_json_error(HTTPStatus.FORBIDDEN, None, -32600, "invalid Origin header")
            return False
        return True

    def _check_accept(self):
        accept = self.headers.get("Accept", "")
        accepted = [part.split(";", 1)[0].strip() for part in accept.split(",")]
        if "application/json" not in accepted or "text/event-stream" not in accepted:
            self._send_empty(HTTPStatus.NOT_ACCEPTABLE)
            return False
        return True

    def _check_content_type(self):
        content_type = self.headers.get("Content-Type", "")
        media_type = content_type.split(";", 1)[0].strip().lower()
        if media_type != "application/json":
            self._send_empty(HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
            return False
        return True

    def _check_protocol_version_header(self):
        version = self.headers.get("MCP-Protocol-Version")
        if version is not None and version != PROTOCOL_VERSION:
            self._send_empty(HTTPStatus.BAD_REQUEST)
            return False
        return True

    def _read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as err:
            raise BridgeError("invalid Content-Length") from err
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except UnicodeDecodeError as err:
            raise BridgeError("request body is not UTF-8") from err
        except json.JSONDecodeError as err:
            raise BridgeError(f"request body is not valid JSON: {err}") from err

    def _send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_json(self, status, payload):
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _send_json_error(self, status, id_value, code, message):
        self._send_json(status, {
            "jsonrpc": "2.0",
            "id": id_value,
            "error": {"code": code, "message": message},
        })


def parse_args():
    parser = argparse.ArgumentParser(description="Bridge lean-beam-mcp stdio to a local MCP Streamable HTTP endpoint.")
    parser.add_argument("--root", required=True)
    parser.add_argument("--server", required=True, help="Path to lean-beam-mcp executable.")
    parser.add_argument("--lean-cmd", default="lean")
    parser.add_argument("--lean-plugin", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--endpoint", default="/mcp")
    parser.add_argument("--ready-file")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    repo_root = Path.cwd()
    command = [
        str(Path(args.server)),
        "--root",
        args.root,
        "--lean-cmd",
        args.lean_cmd,
        "--lean-plugin",
        args.lean_plugin,
    ]
    mcp = StdioMcpServer(command, repo_root, args.timeout)
    try:
        server = BridgeHttpServer(
            (args.host, args.port),
            McpBridgeHandler,
            endpoint=args.endpoint,
            allowed_origins={
                f"http://{args.host}:{0}",
                f"http://{args.host}:{args.port}",
                f"http://127.0.0.1:{args.port}",
                f"http://localhost:{args.port}",
            },
            mcp=mcp,
        )
        server.verbose = args.verbose
        host, port = server.server_address
        server.allowed_origins = {
            f"http://{host}:{port}",
            f"http://127.0.0.1:{port}",
            f"http://localhost:{port}",
        }
        url = f"http://{host}:{port}{args.endpoint}"
        if args.ready_file:
            ready_path = Path(args.ready_file)
            ready_path.write_text(json.dumps({"url": url}) + "\n", encoding="utf-8")
        else:
            print(url, flush=True)
        server.serve_forever()
    finally:
        mcp.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as err:
        print(f"mcp_http_bridge.py: {err}", file=sys.stderr)
        sys.exit(1)
