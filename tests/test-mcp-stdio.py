#!/usr/bin/env python3

import argparse
import collections
import concurrent.futures
import json
import os
import platform
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from mcp_test_util import (
    fail,
    notification_params,
    notifications_by_method,
    progress_messages,
    require,
    require_file_progress_range,
    save_warning_text,
    shared_lib_name,
)


SUPPORTED_PROTOCOL_VERSION = "2025-11-25"
CI_TIMEOUT_TRACKER = "https://github.com/ejgallego/lean-beam/issues/110"
CI_TIMEOUT_TRACKER_NOTE = "\n".join(
    [
        f"Comment on {CI_TIMEOUT_TRACKER} if this scheduler-sensitive timeout hits an unrelated CI PR.",
        "Include:",
        "  - PR URL and branch",
        "  - failing GitHub Actions run URL and job URL",
        "  - job name, runner OS/arch, run attempt, and commit SHA",
        "  - failing test/scenario and this timeout headline",
        (
            "  - MCP stdio pending requests, completed requests, server requests, "
            "notifications, event timeline, stderr/server trace or watchdog lines, and process snapshot"
        ),
        "  - rerun URL and whether the rerun passed or reproduced",
    ]
)


def compact_json(value, limit=700):
    try:
        text = json.dumps(value, separators=(",", ":"), sort_keys=True)
    except TypeError:
        text = repr(value)
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def short_value(value, limit=120):
    return compact_json(value, limit=limit)


def env_enabled(name):
    value = os.environ.get(name)
    if value is None:
        return False
    return value.lower() not in ("", "0", "false", "no", "off")


def runtime_context_lines():
    lines = [
        f"platform: {platform.platform()}",
        f"machine: {platform.machine()}",
        f"python: {platform.python_implementation()} {platform.python_version()}",
        f"os.cpu_count: {os.cpu_count()}",
    ]
    if hasattr(os, "sched_getaffinity"):
        try:
            lines.append(f"sched_getaffinity: {len(os.sched_getaffinity(0))}")
        except OSError as err:
            lines.append(f"sched_getaffinity: <failed: {err}>")
    if hasattr(os, "getloadavg"):
        try:
            load1, load5, load15 = os.getloadavg()
            lines.append(f"loadavg: {load1:.2f} {load5:.2f} {load15:.2f}")
        except OSError as err:
            lines.append(f"loadavg: <failed: {err}>")
    for name in (
        "GITHUB_ACTIONS",
        "RUNNER_OS",
        "RUNNER_ARCH",
        "RUNNER_NAME",
        "ImageOS",
        "LEAN_NUM_THREADS",
        "LEAN_OPTIONS",
        "BEAM_MCP_STDIO_TIMEOUT",
        "BEAM_MCP_SERVER_TRACE",
        "LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS",
    ):
        lines.append(f"{name}: {os.environ.get(name, '<unset>')}")
    return lines


def format_duration_stats(values):
    require(values, "cannot format empty duration stats")
    ordered = sorted(values)
    total = sum(ordered)
    return (
        f"runs={len(ordered)} "
        f"min={ordered[0]:.3f}s "
        f"median={ordered[len(ordered) // 2]:.3f}s "
        f"max={ordered[-1]:.3f}s "
        f"avg={total / len(ordered):.3f}s"
    )


def request_label(method, params):
    label = method
    if method == "tools/call" and isinstance(params, dict):
        tool_name = params.get("name")
        if isinstance(tool_name, str):
            label = f"{method} {tool_name}"
        arguments = params.get("arguments")
        details = []
        if isinstance(arguments, dict):
            for key in ("path", "root", "mode"):
                if key in arguments:
                    details.append(f"{key}={short_value(arguments[key], 80)}")
        meta = params.get("_meta")
        if isinstance(meta, dict) and "progressToken" in meta:
            details.append(f"progressToken={short_value(meta['progressToken'], 80)}")
        if details:
            label = f"{label} ({', '.join(details)})"
    return label


def notification_summary(notification):
    method = notification.get("method")
    params = notification.get("params")
    if method == "notifications/progress" and isinstance(params, dict):
        return (
            f"{method} token={short_value(params.get('progressToken'), 80)} "
            f"progress={short_value(params.get('progress'), 40)} "
            f"message={short_value(params.get('message'), 180)}"
        )
    if method == "notifications/message" and isinstance(params, dict):
        return (
            f"{method} level={short_value(params.get('level'), 40)} "
            f"logger={short_value(params.get('logger'), 80)} "
            f"data={compact_json(params.get('data'), 240)}"
        )
    return compact_json(notification, limit=300)


class McpClient:
    def __init__(
        self,
        repo_root,
        project_root,
        timeout,
        *,
        use_root_arg=True,
        advertise_roots=False,
        roots=None,
        roots_payload=None,
        roots_response="normal",
        root_arg=None,
        label="mcp-client",
        server_trace=False,
        drain_stdout=True,
    ):
        self.repo_root = repo_root
        self.project_root = project_root
        self.timeout = timeout
        self.label = label
        self.server_trace = server_trace or env_enabled("BEAM_MCP_SERVER_TRACE")
        self.runtime_context = runtime_context_lines()
        self.next_id = 0
        self.use_root_arg = use_root_arg
        self.advertise_roots = advertise_roots
        self.roots = [Path(root) for root in (roots if roots is not None else [project_root])]
        self.roots_payload = roots_payload
        self.roots_response = roots_response
        self.root_arg = root_arg if root_arg is not None else project_root
        self.roots_request_count = 0
        self.server_requests = collections.deque(maxlen=20)
        self.pending_extra_response_ids = set()
        self.extra_responses = []
        self.pending_requests = {}
        self.completed_requests = collections.deque(maxlen=20)
        self.notifications = []
        self.event_log = collections.deque(maxlen=80)
        self.started_at = time.monotonic()
        self.last_notification_at = None
        self.stdout_lines = queue.Queue()
        self.stderr_lines = collections.deque(maxlen=80)
        exe = repo_root / ".lake" / "build" / "bin" / "lean-beam-mcp"
        plugin = repo_root / ".lake" / "build" / "lib" / shared_lib_name()
        lean_cmd = shutil.which("lean") or "lean"
        require(exe.exists(), f"missing lean-beam-mcp executable at {exe}")
        require(plugin.exists(), f"missing Beam LSP plugin shared library at {plugin}")
        cmd = [str(exe)]
        if use_root_arg:
            cmd.extend(["--root", str(self.root_arg)])
        cmd.extend(
            [
                "--lean-cmd",
                lean_cmd,
                "--lean-plugin",
                str(plugin),
            ]
        )
        env = os.environ.copy()
        if self.server_trace:
            env["LEAN_BEAM_MCP_TRACE"] = "1"
            env["LEAN_BEAM_BROKER_TRACE"] = "1"
        self.proc = subprocess.Popen(
            cmd,
            cwd=str(repo_root),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.stdout_thread = None
        if drain_stdout:
            self.stdout_thread = threading.Thread(target=self._drain_stdout, daemon=True)
            self.stdout_thread.start()
        self.stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self.stderr_thread.start()
        self._record_event(f"process started pid={self.proc.pid}")

    def _drain_stdout(self):
        try:
            for line in self.proc.stdout:
                self.stdout_lines.put(("line", line))
            self.stdout_lines.put(("eof", None))
        except Exception as err:
            self.stdout_lines.put(("error", str(err)))

    def _drain_stderr(self):
        try:
            for line in self.proc.stderr:
                self.stderr_lines.append(line.rstrip("\n"))
        except Exception as err:
            self.stderr_lines.append(f"<stderr drain failed: {err}>")

    def _record_event(self, label):
        self.event_log.append({"at": time.monotonic(), "label": label})

    def close(self):
        if self.proc.poll() is None:
            try:
                self.shutdown()
            except Exception:
                self.proc.kill()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        if self.stdout_thread is not None:
            self.stdout_thread.join(timeout=1)
        self.stderr_thread.join(timeout=1)
        stderr = "\n".join(self.stderr_lines)
        if not self.server_trace:
            require(stderr.strip() == "", f"lean-beam-mcp wrote unexpected stderr:\n{stderr}")

    def send_message(self, message):
        require(self.proc.poll() is None, "lean-beam-mcp exited before request")
        line = json.dumps(message, separators=(",", ":"))
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def handle_server_request(self, request):
        method = request.get("method")
        request_id = request.get("id")
        self._record_event(f"server request id {request_id}: {method}")
        self.server_requests.append(
            {
                "id": request_id,
                "method": method,
                "params": request.get("params"),
                "received": time.monotonic(),
            }
        )
        if method == "roots/list":
            self.roots_request_count += 1
            if self.roots_response == "error":
                self.send_message(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {"code": -32603, "message": "roots unavailable"},
                    }
                )
                return
            if self.roots_response == "unrelated_then_normal":
                extra_id = "during-roots"
                self.pending_extra_response_ids.add(extra_id)
                self.send_message({"jsonrpc": "2.0", "id": extra_id, "method": "ping"})
            if self.roots_payload is not None:
                roots = self.roots_payload
            else:
                roots = [
                    {"uri": root.resolve().as_uri(), "name": root.name or "project"}
                    for root in self.roots
                ]
            self.send_message({"jsonrpc": "2.0", "id": request_id, "result": {"roots": roots}})
            return
        self.send_message(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"unsupported server request: {method}"},
            }
        )

    def _request_label(self, request_id):
        pending = self.pending_requests.get(request_id)
        if pending is None:
            return "<unknown request>"
        return pending["label"]

    def _client_context(self):
        roots = [str(root) for root in self.roots]
        return "\n".join(
            [
                f"client label: {self.label}",
                f"project root: {self.project_root}",
                f"process pid: {self.proc.pid}",
                f"use_root_arg: {self.use_root_arg}",
                f"root_arg: {self.root_arg if self.use_root_arg else '<none>'}",
                f"advertise_roots: {self.advertise_roots}",
                f"configured roots: {roots}",
                f"roots_response: {self.roots_response}",
                f"roots_request_count: {self.roots_request_count}",
                f"pending_extra_response_ids: {sorted(self.pending_extra_response_ids)}",
                f"extra_responses_seen: {len(self.extra_responses)}",
                "runtime context:",
                *[f"  {line}" for line in self.runtime_context],
            ]
        )

    def _pending_requests_summary(self):
        now = time.monotonic()
        lines = []
        for request_id, pending in sorted(self.pending_requests.items()):
            age = now - pending["started"]
            lines.append(
                f"  id {request_id}: {pending['label']} age={age:.3f}s "
                f"params={compact_json(pending.get('params'), 500)}"
            )
        return "\n".join(lines) if lines else "  <none>"

    def _completed_requests_summary(self):
        completed = "\n".join(
            f"  id {entry['id']}: {entry['label']} in {entry['elapsed']:.3f}s"
            for entry in self.completed_requests
        )
        return completed or "  <none>"

    def _server_requests_summary(self):
        now = time.monotonic()
        lines = []
        for entry in self.server_requests:
            age = now - entry["received"]
            lines.append(
                f"  id {entry['id']}: {entry['method']} age={age:.3f}s "
                f"params={compact_json(entry.get('params'), 300)}"
            )
        return "\n".join(lines) if lines else "  <none>"

    def _notifications_summary(self):
        rows = self.notifications[-12:]
        if not rows:
            return "  <none>"
        return "\n".join(f"  {notification_summary(notification)}" for notification in rows)

    def _event_timeline_summary(self):
        now = time.monotonic()
        if not self.event_log:
            return "  <none>"
        return "\n".join(
            f"  +{entry['at'] - self.started_at:.3f}s "
            f"({now - entry['at']:.3f}s ago): {entry['label']}"
            for entry in self.event_log
        )

    def _last_notification_summary(self):
        if self.last_notification_at is None:
            return "last notification: <none>"
        return f"last notification: {time.monotonic() - self.last_notification_at:.3f}s ago"

    def _process_snapshot(self):
        try:
            out = subprocess.run(
                ["ps", "-ef"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
                check=False,
            )
        except Exception as err:
            return f"<ps failed: {err}>"
        needles = [
            "lean-beam-mcp",
            "beam-daemon",
            "beam-daemon-smo",
            "lean --server",
        ]
        lines = [
            line
            for line in out.stdout.splitlines()
            if any(needle in line for needle in needles)
        ]
        return "\n".join(lines[-40:]) if lines else "<no Beam/Lean processes found>"

    def _timeout_message(self, expected_id):
        label = self._request_label(expected_id)
        pending = self.pending_requests.get(expected_id)
        elapsed = time.monotonic() - pending["started"] if pending is not None else 0.0
        stderr_tail = "\n".join(self.stderr_lines)
        process_snapshot = self._process_snapshot()
        return (
            f"timed out waiting for MCP response id {expected_id} ({label}) "
            f"for client {self.label!r} after {elapsed:.3f}s\n"
            f"MCP client context:\n{self._client_context()}\n"
            f"pending MCP requests:\n{self._pending_requests_summary()}\n"
            f"recent completed MCP requests:\n{self._completed_requests_summary()}\n"
            f"recent server requests received from lean-beam-mcp:\n{self._server_requests_summary()}\n"
            f"recent notifications:\n{self._notifications_summary()}\n"
            f"MCP event timeline ({self._last_notification_summary()}):\n"
            f"{self._event_timeline_summary()}\n"
            f"CI timeout tracker:\n{CI_TIMEOUT_TRACKER_NOTE}\n"
            f"lean-beam-mcp stderr tail:\n{stderr_tail or '  <empty>'}\n"
            f"process snapshot:\n{process_snapshot}"
        )

    def read_response(self, expected_id):
        require(self.stdout_thread is not None, "MCP stdout reader is disabled")
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(self._timeout_message(expected_id))
            try:
                kind, payload = self.stdout_lines.get(timeout=min(remaining, 0.1))
            except queue.Empty:
                if self.proc.poll() is not None:
                    self.stdout_thread.join(timeout=1)
                    self.stderr_thread.join(timeout=1)
                    stderr = "\n".join(self.stderr_lines)
                    fail(f"lean-beam-mcp exited early with code {self.proc.returncode}\n{stderr}")
                continue
            if kind == "error":
                fail(f"failed reading lean-beam-mcp stdout: {payload}")
            if kind == "eof":
                fail(f"lean-beam-mcp closed stdout before response id {expected_id}")
            line = payload
            try:
                response = json.loads(line)
            except json.JSONDecodeError as err:
                fail(f"stdout line is not valid JSON: {err}: {line!r}")
            require(response.get("jsonrpc") == "2.0", f"bad JSON-RPC response: {response}")
            if "method" in response and "id" in response:
                self.handle_server_request(response)
                continue
            if "method" in response:
                self.last_notification_at = time.monotonic()
                self.notifications.append(response)
                self._record_event(f"server notification: {notification_summary(response)}")
                continue
            if response.get("id") in self.pending_extra_response_ids:
                self.extra_responses.append(response)
                self.pending_extra_response_ids.remove(response.get("id"))
                self._record_event(f"extra response id {response.get('id')}: {compact_json(response, 240)}")
                continue
            require(response.get("id") == expected_id, f"expected response id {expected_id}, got {response}")
            pending = self.pending_requests.pop(expected_id, None)
            if pending is not None:
                elapsed = time.monotonic() - pending["started"]
                self.completed_requests.append(
                    {
                        "id": expected_id,
                        "label": pending["label"],
                        "elapsed": elapsed,
                    }
                )
                self._record_event(f"response id {expected_id}: {pending['label']} elapsed={elapsed:.3f}s")
            return response

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        label = request_label(method, params)
        self.pending_requests[self.next_id] = {
            "label": label,
            "method": method,
            "params": params,
            "started": time.monotonic(),
        }
        self._record_event(f"request id {self.next_id}: {label}")
        self.send_message(message)
        return self.read_response(self.next_id)

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._record_event(f"client notification: {method}")
        self.send_message(message)

    def initialize(self):
        capabilities = {}
        if self.advertise_roots:
            capabilities["roots"] = {"listChanged": False}
        response = self.request(
            "initialize",
            {
                "protocolVersion": SUPPORTED_PROTOCOL_VERSION,
                "capabilities": capabilities,
                "clientInfo": {"name": "lean-beam-mcp-test", "version": "0"},
            },
        )
        result = expect_result(response)
        require(
            result.get("protocolVersion") == SUPPORTED_PROTOCOL_VERSION,
            f"server negotiated unexpected protocol version: {result}",
        )
        tools = result.get("capabilities", {}).get("tools")
        require(isinstance(tools, dict), f"initialize did not advertise tools capability: {result}")
        logging = result.get("capabilities", {}).get("logging")
        require(isinstance(logging, dict), f"initialize did not advertise logging capability: {result}")
        self.notify("notifications/initialized")

    def shutdown(self):
        if self.proc.poll() is None:
            response = self.request("shutdown")
            expect_result(response)
        if self.proc.stdin and not self.proc.stdin.closed:
            self.proc.stdin.close()

    def call_tool(self, name, arguments=None):
        params = {"name": name}
        if arguments is not None:
            params["arguments"] = arguments
        response = self.request("tools/call", params)
        result = expect_result(response)
        require(result.get("isError") is not True, f"tool {name} returned MCP tool error: {result}")
        content = result.get("content")
        require(isinstance(content, list) and content, f"tool {name} missing content: {result}")
        require(content[0].get("type") == "text", f"tool {name} first content block is not text: {result}")
        structured = result.get("structuredContent")
        require(isinstance(structured, dict), f"tool {name} missing structuredContent: {result}")
        return structured

    def progress_notifications(self, token):
        rows = []
        for notification in notifications_by_method(self.notifications, "notifications/progress"):
            params = notification_params(notification, "notifications/progress", "progress notification")
            if params.get("progressToken") == token:
                rows.append(notification)
        return rows


def expect_result(response):
    if "error" in response:
        fail(f"unexpected JSON-RPC error response: {response}")
    result = response.get("result")
    require(result is not None, f"missing JSON-RPC result: {response}")
    return result


def expect_error_code(response, code):
    error = response.get("error")
    require(isinstance(error, dict), f"expected JSON-RPC error response, got {response}")
    require(error.get("code") == code, f"expected JSON-RPC error code {code}, got {response}")
    return error


def write_save_warning_file(project_root, marker):
    (project_root / "SaveSmoke" / "B.lean").write_text(save_warning_text(marker), encoding="utf-8")


def diagnostic_log_notifications(client):
    rows = []
    for notification in notifications_by_method(client.notifications, "notifications/message"):
        params = notification_params(notification, "notifications/message", "diagnostic log notification")
        if params.get("logger") == "lean.diagnostic":
            rows.append(notification)
    return rows


def expect_diagnostic_log(client, *, level, severity, path):
    for notification in diagnostic_log_notifications(client):
        params = notification_params(notification, "notifications/message", "diagnostic log notification")
        data = params.get("data", {})
        if (
            params.get("level") == level
            and isinstance(data, dict)
            and data.get("severity") == severity
            and data.get("path") == path
        ):
            require(isinstance(data.get("uri"), str), f"diagnostic log missing uri: {notification}")
            require(isinstance(data.get("version"), int), f"diagnostic log missing version: {notification}")
            require(isinstance(data.get("range"), dict), f"diagnostic log missing range: {notification}")
            require(isinstance(data.get("message"), str) and data["message"], f"diagnostic log missing message: {notification}")
            return notification
    fail(f"missing {level}/{severity} diagnostic log for {path}: {client.notifications}")


def expect_reply_diagnostic(sync, *, severity, path):
    diagnostics = sync.get("diagnostics")
    require(isinstance(diagnostics, list) and diagnostics, f"sync reply missing diagnostics: {sync}")
    for diagnostic in diagnostics:
        if (
            isinstance(diagnostic, dict)
            and diagnostic.get("severity") == severity
            and diagnostic.get("path") == path
        ):
            require(isinstance(diagnostic.get("uri"), str), f"reply diagnostic missing uri: {diagnostic}")
            require(isinstance(diagnostic.get("version"), int), f"reply diagnostic missing version: {diagnostic}")
            require(isinstance(diagnostic.get("range"), dict), f"reply diagnostic missing range: {diagnostic}")
            require(isinstance(diagnostic.get("message"), str) and diagnostic["message"], f"reply diagnostic missing message: {diagnostic}")
            return diagnostic
    fail(f"missing {severity} reply diagnostic for {path}: {sync}")


def expect_error_message_contains(response, code, needle):
    error = expect_error_code(response, code)
    message = error.get("message")
    require(isinstance(message, str), f"error response missing message: {response}")
    require(needle in message, f"expected error message to contain {needle!r}, got {response}")
    return error


def expect_tool_error_code(response, code):
    result = expect_result(response)
    require(result.get("isError") is True, f"expected MCP tool error result, got {response}")
    structured = result.get("structuredContent")
    require(isinstance(structured, dict), f"tool error missing structuredContent: {response}")
    require(structured.get("code") == code, f"expected tool error code {code}, got {response}")
    return structured


def require_version_mismatch_data(error, expected_version, accepted_version, label, *, expected_uri_suffix=None):
    data = error.get("data")
    require(isinstance(data, dict), f"{label}: tool error missing data: {error}")
    require(
        data.get("reason") == "documentVersionMismatch",
        f"{label}: expected documentVersionMismatch data, got {error}",
    )
    require(
        data.get("expectedVersion") == expected_version,
        f"{label}: expected expectedVersion={expected_version}, got {error}",
    )
    require(
        data.get("acceptedVersion") == accepted_version,
        f"{label}: expected acceptedVersion={accepted_version}, got {error}",
    )
    require(
        data.get("currentVersion") == accepted_version,
        f"{label}: expected currentVersion={accepted_version}, got {error}",
    )
    if expected_uri_suffix is not None:
        uri = data.get("uri")
        require(
            isinstance(uri, str) and uri.endswith(expected_uri_suffix),
            f"{label}: expected uri ending in {expected_uri_suffix!r}, got {error}",
        )


def require_roots_requests(client, expected, label):
    require(
        client.roots_request_count == expected,
        f"{label}: expected {expected} roots/list request(s), got {client.roots_request_count}",
    )


def expect_extra_error_code(client, response_id, code, label):
    for response in client.extra_responses:
        if response.get("id") == response_id:
            expect_error_code(response, code)
            return
    fail(f"{label}: missing extra response id {response_id}; saw {client.extra_responses}")


def require_success(label, structured):
    require(structured.get("success") is True, f"{label} should succeed: {structured}")


def require_failure(label, structured):
    require(structured.get("success") is False, f"{label} should fail semantically: {structured}")


def init_workspace(client, root, *, mode=None, invalidated_handles=False, previous_root=None):
    args = {"root": str(root)}
    if mode is not None:
        args["mode"] = mode
    structured = client.call_tool("lean_init_workspace", args)
    require(structured.get("initialized") is True, f"init workspace did not initialize: {structured}")
    require(
        Path(structured.get("root")).resolve() == Path(root).resolve(),
        f"init workspace returned wrong root for {root}: {structured}",
    )
    require(
        Path(structured.get("active_root")).resolve() == Path(root).resolve(),
        f"init workspace returned wrong active_root for {root}: {structured}",
    )
    expected_mode = mode or "set"
    require(
        structured.get("mode") == expected_mode,
        f"init workspace returned wrong mode {expected_mode!r}: {structured}",
    )
    require(
        isinstance(structured.get("runtime_reused"), bool),
        f"init workspace missing runtime_reused flag: {structured}",
    )
    require(
        isinstance(structured.get("invalidated_handles"), bool),
        f"init workspace missing invalidated_handles flag: {structured}",
    )
    capabilities = structured.get("capabilities")
    require(isinstance(capabilities, list), f"init workspace missing capabilities: {structured}")
    for capability in ["beam_version", "lean_update", "lean_sync", "lean_save", "lean_run_at", "lean_hover", "lean_goals_prev", "lean_goals_after"]:
        require(capability in capabilities, f"init workspace capabilities missing {capability}: {structured}")
    require("$/lean/runAt" not in capabilities, f"init workspace exposed raw LSP capability: {structured}")
    require(
        structured.get("invalidated_handles") is invalidated_handles,
        f"init workspace returned wrong invalidated_handles={invalidated_handles}: {structured}",
    )
    if previous_root is None:
        require("previous_root" not in structured, f"init workspace unexpectedly returned previous_root: {structured}")
    else:
        require(
            Path(structured.get("previous_root")).resolve() == Path(previous_root).resolve(),
            f"init workspace returned wrong previous_root {previous_root}: {structured}",
        )
    return structured


def require_progress_sequence(notifications, token, label):
    require(notifications, f"{label}: expected progress notifications for {token!r}")
    previous = None
    for notification in notifications:
        params = notification_params(notification, "notifications/progress", label)
        require(params.get("progressToken") == token, f"{label}: wrong progress token: {notification}")
        progress = params.get("progress")
        require(isinstance(progress, (int, float)), f"{label}: progress is not numeric: {notification}")
        if previous is not None:
            require(progress > previous, f"{label}: progress is not strictly increasing: {notifications}")
        previous = progress
        message = params.get("message")
        require(message is None or isinstance(message, str), f"{label}: progress message is not a string: {notification}")
    return [notification["params"]["progress"] for notification in notifications]


def require_progress_message_contains(notifications, label, *needles):
    messages = [message for message in progress_messages(notifications) if isinstance(message, str)]
    for needle in needles:
        require(
            any(needle in message for message in messages),
            f"{label}: expected a progress message containing {needle!r}, got {messages}",
        )


def require_file_progress_range_end(structured, label, range_end):
    require_file_progress_range(structured, label)
    progress = structured["file_progress"]
    require(
        progress.get("rangeEndLine") == range_end,
        f"{label}: expected file_progress rangeEndLine={range_end}, got {progress}",
    )


def expect_stale_handle(client, handle, label):
    response = client.request(
        "tools/call",
        {
            "name": "lean_run_with",
            "arguments": {
                "path": "PositionEmptyLine.lean",
                "handle": handle,
                "text": "def mcpResetAfter : Nat := mcpResetBase + 1",
            },
        },
    )
    error = expect_tool_error_code(response, "contentModified")
    require(
        "stale backend session" in error.get("message", ""),
        f"{label}: handle should be stale after reset: {error}",
    )


def run_iteration(client, suffix):
    update = client.call_tool("lean_update", {"path": "PositionEmptyLine.lean"})
    require(
        Path(update.get("active_root")).resolve() == client.project_root.resolve(),
        f"update returned wrong active_root: {update}",
    )
    version = update.get("version")
    require(isinstance(version, int), f"update did not return a document version: {update}")
    changed = update.get("changed")
    require(isinstance(changed, bool), f"update did not return changed flag: {update}")

    command_update = client.call_tool("lean_update", {"path": "CommandA.lean"})
    command_version = command_update.get("version")
    require(isinstance(command_version, int), f"CommandA update did not return a version: {command_update}")
    command_path = client.project_root / "CommandA.lean"
    command_text = command_path.read_text(encoding="utf-8")
    command_path.write_text(f"{command_text}\n-- mcp stale-version {suffix}\n", encoding="utf-8")
    command_changed = client.call_tool("lean_update", {"path": "CommandA.lean"})
    accepted_version = command_changed.get("version")
    require(isinstance(accepted_version, int), f"CommandA changed update did not return a version: {command_changed}")
    stale_response = client.request(
        "tools/call",
        {
            "name": "lean_run_at",
            "arguments": {
                "path": "CommandA.lean",
                "version": command_version,
                "line": 0,
                "character": 2,
                "text": "#check answerA",
            },
        },
    )
    stale_error = expect_tool_error_code(stale_response, "contentModified")
    require_version_mismatch_data(
        stale_error,
        command_version,
        accepted_version,
        "stale MCP lean_run_at",
        expected_uri_suffix="/CommandA.lean",
    )

    probe = client.call_tool(
        "lean_run_at",
        {
            "path": "PositionEmptyLine.lean",
            "version": version,
            "line": 1,
            "character": 0,
            "text": f"def mcpProbe{suffix} : Nat :=\n  42",
        },
    )
    require_success("lean_run_at multiline probe", probe)
    require(probe.get("next_handle") is None, f"plain lean_run_at leaked a follow-up handle: {probe}")

    broken = client.call_tool(
        "lean_run_at",
        {
            "path": "PositionEmptyLine.lean",
            "version": version,
            "line": 1,
            "character": 0,
            "text": f"def mcpBroken{suffix} : Nat := \"bad\"",
        },
    )
    require_failure("semantic failure probe", broken)
    require(broken.get("next_handle") is None, f"semantic failure leaked a follow-up handle: {broken}")

    minted = client.call_tool(
        "lean_run_at_handle",
        {
            "path": "PositionEmptyLine.lean",
            "version": version,
            "line": 1,
            "character": 0,
            "text": f"def mcpBase{suffix} : Nat := 1",
        },
    )
    require_success("handle mint probe", minted)
    base_handle = minted.get("next_handle")
    require(isinstance(base_handle, dict), f"handle mint did not return next_handle: {minted}")

    continued = client.call_tool(
        "lean_run_with",
        {
            "path": "PositionEmptyLine.lean",
            "handle": base_handle,
            "text": f"def mcpNext{suffix} : Nat := mcpBase{suffix} + 1",
        },
    )
    require_success("handle continuation probe", continued)
    next_handle = continued.get("next_handle")
    require(isinstance(next_handle, dict), f"handle continuation did not return next_handle: {continued}")

    linear = client.call_tool(
        "lean_run_with_linear",
        {
            "path": "PositionEmptyLine.lean",
            "handle": next_handle,
            "text": f"def mcpLinear{suffix} : Nat := mcpNext{suffix} + 1",
        },
    )
    require_success("linear handle continuation probe", linear)
    linear_handle = linear.get("next_handle")
    require(isinstance(linear_handle, dict), f"linear continuation did not return next_handle: {linear}")

    client.call_tool("lean_release", {"path": "PositionEmptyLine.lean", "handle": linear_handle})
    client.call_tool("lean_release", {"path": "PositionEmptyLine.lean", "handle": base_handle})

    goal_update = client.call_tool("lean_update", {"path": "GoalSmoke.lean"})
    goal_version = goal_update.get("version")
    require(isinstance(goal_version, int), f"GoalSmoke update did not return a version: {goal_update}")
    goals_prev = client.call_tool(
        "lean_goals_prev",
        {"path": "GoalSmoke.lean", "version": goal_version, "line": 1, "character": 2},
    )
    prev_goals = goals_prev.get("goals")
    require(isinstance(prev_goals, list) and prev_goals, f"goals-prev returned no goals: {goals_prev}")
    require(prev_goals[0].get("target") == "True", f"goals-prev returned unexpected goal: {goals_prev}")

    goals_after = client.call_tool(
        "lean_goals_after",
        {"path": "GoalSmoke.lean", "version": goal_version, "line": 1, "character": 2},
    )
    require(goals_after.get("goals") == [], f"goals-after should return no goals: {goals_after}")

    client.call_tool("lean_close", {"path": "PositionEmptyLine.lean"})
    client.call_tool("lean_close", {"path": "GoalSmoke.lean"})


def run_cycle(
    repo_root,
    fixture_root,
    cycle,
    iterations,
    timeout,
    *,
    use_root_arg=True,
    advertise_roots=False,
    expected_roots_requests=0,
):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            use_root_arg=use_root_arg,
            advertise_roots=advertise_roots,
            label=f"cycle-{cycle}",
        )
        try:
            pre_init = client.request("tools/list")
            expect_error_code(pre_init, -32600)
            client.initialize()

            raw_tool = client.request(
                "tools/call",
                {"name": "$/lean/runAt", "arguments": {}},
            )
            expect_error_code(raw_tool, -32602)

            bad_known_tool_input = client.request(
                "tools/call",
                {
                    "name": "lean_run_at",
                    "arguments": {
                        "path": "PositionEmptyLine.lean",
                        "line": 1,
                        "character": 0,
                    },
                },
            )
            expect_tool_error_code(bad_known_tool_input, "invalidInput")

            tools = expect_result(client.request("tools/list")).get("tools")
            names = {tool.get("name") for tool in tools}
            require("beam_version" in names, f"tools/list missing beam_version: {tools}")
            require("lean_init_workspace" in names, f"tools/list missing lean_init_workspace: {tools}")
            require("lean_update" in names, f"tools/list missing lean_update: {tools}")
            require("lean_run_at" in names, f"tools/list missing lean_run_at: {tools}")
            require("$/lean/runAt" not in names, f"tools/list exposed raw LSP method: {tools}")
            require("lean_request_at" not in names, f"tools/list exposed raw request escape hatch: {tools}")

            version = client.call_tool("beam_version")
            require(version.get("name") == "lean-beam-mcp", f"beam_version returned wrong name: {version}")
            require(version.get("version") == "0.1.0-alpha", f"beam_version returned wrong version: {version}")
            require(version.get("mcp_protocol") == SUPPORTED_PROTOCOL_VERSION, f"beam_version returned wrong protocol: {version}")
            require(isinstance(version.get("server_binary"), str) and version["server_binary"], f"beam_version missing server_binary: {version}")
            require(version.get("runtime_active") is False, f"beam_version should not start runtime: {version}")

            for iteration in range(iterations):
                run_iteration(client, f"Cycle{cycle}Iter{iteration}")
            require_roots_requests(client, expected_roots_requests, f"cycle {cycle}")
        finally:
            client.close()


def run_relative_root_arg(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-relative-root-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        relative_root = os.path.relpath(project_root, repo_root)
        client = McpClient(repo_root, project_root, timeout, root_arg=relative_root, label="relative-root-arg")
        try:
            client.initialize()
            sync = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                Path(sync.get("active_root")).resolve() == project_root.resolve(),
                f"relative --root returned wrong active_root: {sync}",
            )
            require_roots_requests(client, 0, "relative --root")
        finally:
            client.close()


def run_diagnostic_logging(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-diagnostic-logs-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        client = McpClient(repo_root, project_root, timeout, label="diagnostic-logging")
        try:
            client.initialize()
            write_save_warning_file(project_root, "-- mcp stdio diagnostic log")
            sync = client.call_tool(
                "lean_sync",
                {"path": "SaveSmoke/B.lean", "full_diagnostics": True, "include_diagnostics": True},
            )
            require("saveReady" not in sync, f"warning-only sync should omit top-level saveReady: {sync}")
            require("warningCount" not in sync, f"warning-only sync should omit top-level warningCount: {sync}")
            readiness = sync.get("syncSummary", {}).get("readiness", {}).get("current", {})
            require(readiness.get("saveReady") is True, f"warning-only sync should be save-ready: {sync}")
            require(
                readiness.get("warningCount", 0) >= 1,
                f"warning-only sync summary should report readiness warnings: {sync}",
            )
            expect_reply_diagnostic(sync, severity="warning", path="SaveSmoke/B.lean")
            expect_diagnostic_log(client, level="warning", severity="warning", path="SaveSmoke/B.lean")

            expect_result(client.request("logging/setLevel", {"level": "error"}))
            client.notifications.clear()
            write_save_warning_file(project_root, "-- mcp stdio warning suppressed")
            sync = client.call_tool("lean_sync", {"path": "SaveSmoke/B.lean", "full_diagnostics": True})
            require("saveReady" not in sync, f"suppressed warning sync should omit top-level saveReady: {sync}")
            readiness = sync.get("syncSummary", {}).get("readiness", {}).get("current", {})
            require(readiness.get("saveReady") is True, f"suppressed warning sync should be save-ready: {sync}")
            require("warningCount" not in sync, f"suppressed warning sync should omit top-level warningCount: {sync}")
            require("diagnostics" not in sync, f"sync reply should omit diagnostics without include_diagnostics: {sync}")
            require(
                diagnostic_log_notifications(client) == [],
                f"warning-only sync should not log diagnostics at error level: {client.notifications}",
            )

            client.notifications.clear()
            (project_root / "SaveSmoke" / "B.lean").write_text('def bVal : Nat := "broken"\n', encoding="utf-8")
            sync = client.call_tool("lean_sync", {"path": "SaveSmoke/B.lean", "include_diagnostics": True})
            require("saveReady" not in sync, f"broken sync should omit top-level saveReady: {sync}")
            require("errorCount" not in sync, f"broken sync should omit top-level errorCount: {sync}")
            require("warningCount" not in sync, f"broken sync should omit top-level warningCount: {sync}")
            summary = sync.get("syncSummary", {})
            current = summary.get("diagnostics", {}).get("current", {})
            readiness = summary.get("readiness", {}).get("current", {})
            require(current.get("error", 0) >= 1, f"broken sync summary should count errors: {sync}")
            require(readiness.get("saveReady") is False, f"broken sync summary should not be save-ready: {sync}")
            require(
                readiness.get("errorCount", 0) >= 1,
                f"broken sync summary should report readiness errors: {sync}",
            )
            expect_reply_diagnostic(sync, severity="error", path="SaveSmoke/B.lean")
            require(
                all(diagnostic.get("severity") == "error" for diagnostic in sync.get("diagnostics", [])),
                f"default replayed diagnostics should be error-only: {sync}",
            )
            expect_diagnostic_log(client, level="error", severity="error", path="SaveSmoke/B.lean")
        finally:
            client.close()


FOCUSED_SYNC_SCENARIOS = {
    "progress-roots-sync": {
        "use_root_arg": False,
        "advertise_roots": True,
        "progress": True,
        "expected_roots_requests": 1,
    },
    "progress-explicit-sync": {
        "use_root_arg": True,
        "advertise_roots": False,
        "progress": True,
        "expected_roots_requests": 0,
    },
    "no-progress-roots-sync": {
        "use_root_arg": False,
        "advertise_roots": True,
        "progress": False,
        "expected_roots_requests": 1,
    },
    "no-progress-explicit-sync": {
        "use_root_arg": True,
        "advertise_roots": False,
        "progress": False,
        "expected_roots_requests": 0,
    },
}


def run_focused_sync_once(repo_root, fixture_root, timeout, label, scenario, server_trace=False):
    config = FOCUSED_SYNC_SCENARIOS[scenario]
    with tempfile.TemporaryDirectory(prefix=f"lean-beam-mcp-{scenario}-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            use_root_arg=config["use_root_arg"],
            advertise_roots=config["advertise_roots"],
            label=label,
            server_trace=server_trace,
        )
        try:
            init_started = time.monotonic()
            client.initialize()
            init_elapsed = time.monotonic() - init_started

            token = f"{scenario}-token"
            call_params = {
                "name": "lean_sync",
                "arguments": {"path": "PositionEmptyLine.lean"},
            }
            if config["progress"]:
                call_params["_meta"] = {"progressToken": token}
            before_notifications = len(client.notifications)
            sync_started = time.monotonic()
            response = client.request("tools/call", call_params)
            sync_elapsed = time.monotonic() - sync_started
            result = expect_result(response)
            require(result.get("isError") is not True, f"{label}: lean_sync failed: {result}")
            require_roots_requests(client, config["expected_roots_requests"], label)
            if config["progress"]:
                notifications = client.progress_notifications(token)
                require_progress_sequence(notifications, token, f"{label} progress")
                require_progress_message_contains(
                    notifications,
                    f"{label} progress",
                    "preparing lean_sync",
                    "running lean_sync",
                    "lean_sync fileProgress",
                    "range",
                    "done=true",
                )
            else:
                notifications = notifications_by_method(
                    client.notifications[before_notifications:],
                    "notifications/progress",
                )
                require(
                    not notifications,
                    f"{label}: sync without progress token emitted progress notifications: {notifications}",
                )
            return {
                "init_elapsed": init_elapsed,
                "sync_elapsed": sync_elapsed,
                "notification_count": len(notifications),
                "roots_request_count": client.roots_request_count,
            }
        finally:
            client.close()


def run_progress_roots_sync_once(repo_root, fixture_root, timeout, label):
    return run_focused_sync_once(repo_root, fixture_root, timeout, label, "progress-roots-sync")


def run_progress_notification_smoke(repo_root, fixture_root, timeout, server_trace=False, label_prefix="progress"):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-progress-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label=f"{label_prefix}-explicit-root",
            server_trace=server_trace,
        )
        try:
            client.initialize()

            invalid_token = client.request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {"path": "PositionEmptyLine.lean"},
                    "_meta": {"progressToken": True},
                },
            )
            expect_error_code(invalid_token, -32602)
            decimal_token = client.request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {"path": "PositionEmptyLine.lean"},
                    "_meta": {"progressToken": 1.5},
                },
            )
            expect_error_code(decimal_token, -32602)

            before_no_token = len(client.notifications)
            no_token = client.request(
                "tools/call",
                {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
            )
            result = expect_result(no_token)
            require(result.get("isError") is not True, f"lean_sync without progress token failed: {result}")
            no_token_notifications = client.notifications[before_no_token:]
            require(
                not notifications_by_method(no_token_notifications, "notifications/progress"),
                f"lean_sync without progress token emitted progress notifications: {no_token_notifications}",
            )

            token = "sync-progress-token"
            before_token = len(client.notifications)
            with_token = client.request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {"path": "CommandA.lean"},
                    "_meta": {"progressToken": token},
                },
            )
            result = expect_result(with_token)
            require(result.get("isError") is not True, f"lean_sync with progress token failed: {result}")
            structured = result.get("structuredContent")
            require(isinstance(structured, dict), f"lean_sync with progress token missing structuredContent: {result}")
            require_file_progress_range_end(structured, "lean_sync progress", 1)
            token_notifications = [
                notification
                for notification in notifications_by_method(
                    client.notifications[before_token:],
                    "notifications/progress",
                )
            ]
            require_progress_sequence(token_notifications, token, "lean_sync progress")
            require_progress_message_contains(
                token_notifications,
                "lean_sync progress",
                "running lean_sync",
                "lean_sync fileProgress",
                "rangeEndLine=1",
                "done=true",
            )

            progress_count_after_response = len(client.progress_notifications(token))
            ping = client.request("ping")
            expect_result(ping)
            require(
                len(client.progress_notifications(token)) == progress_count_after_response,
                f"progress notifications continued after final response: {client.progress_notifications(token)}",
            )
        finally:
            client.close()

    run_focused_sync_once(
        repo_root,
        fixture_root,
        timeout,
        f"{label_prefix}-roots-list",
        "progress-roots-sync",
        server_trace,
    )


def run_focused_sync_repro(repo_root, fixture_root, timeout, runs, slow_threshold, scenario, server_trace):
    require(runs > 0, "--repro-runs must be positive")
    init_durations = []
    sync_durations = []
    started = time.monotonic()
    for index in range(runs):
        label = f"{scenario}-repro-{index + 1}-of-{runs}"
        result = run_focused_sync_once(repo_root, fixture_root, timeout, label, scenario, server_trace)
        init_durations.append(result["init_elapsed"])
        sync_durations.append(result["sync_elapsed"])
        sync_elapsed = result["sync_elapsed"]
        if slow_threshold is None or sync_elapsed >= slow_threshold:
            print(
                f"{label}: init={result['init_elapsed']:.3f}s "
                f"sync={sync_elapsed:.3f}s "
                f"roots/list={result['roots_request_count']} "
                f"progress_notifications={result['notification_count']}",
                file=sys.stderr,
            )
    elapsed = time.monotonic() - started
    print(
        f"{scenario} repro summary: "
        f"elapsed={elapsed:.3f}s "
        f"init[{format_duration_stats(init_durations)}] "
        f"sync[{format_duration_stats(sync_durations)}]",
        file=sys.stderr,
    )


PARALLEL_PROGRESS_SMOKE_SCENARIO = "progress-smoke-parallel"


def run_parallel_progress_smoke_repro(
    repo_root,
    fixture_root,
    timeout,
    runs,
    workers,
    slow_threshold,
    server_trace,
):
    require(runs > 0, "--repro-runs must be positive")
    require(workers > 0, "--parallel-workers must be positive")
    stop_event = threading.Event()
    print_lock = threading.Lock()
    started = time.monotonic()

    def worker(worker_index):
        durations = []
        for run_index in range(runs):
            if stop_event.is_set():
                break
            label = f"parallel-w{worker_index + 1}-r{run_index + 1}-of-{runs}"
            run_started = time.monotonic()
            try:
                run_progress_notification_smoke(
                    repo_root,
                    fixture_root,
                    timeout,
                    server_trace=server_trace,
                    label_prefix=label,
                )
            except Exception as err:
                stop_event.set()
                elapsed = time.monotonic() - run_started
                raise RuntimeError(f"{label}: progress smoke failed after {elapsed:.3f}s\n{err}") from err
            elapsed = time.monotonic() - run_started
            durations.append(elapsed)
            if slow_threshold is not None and elapsed >= slow_threshold:
                with print_lock:
                    print(f"{label}: progress-smoke={elapsed:.3f}s", file=sys.stderr)
        with print_lock:
            if durations:
                print(
                    f"parallel worker {worker_index + 1} summary: "
                    f"{format_duration_stats(durations)}",
                    file=sys.stderr,
                )
            elif stop_event.is_set():
                print(f"parallel worker {worker_index + 1} stopped before starting", file=sys.stderr)
        return durations

    durations = []
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=workers)
    futures = [executor.submit(worker, worker_index) for worker_index in range(workers)]
    try:
        for future in concurrent.futures.as_completed(futures):
            durations.extend(future.result())
    except Exception:
        stop_event.set()
        for future in futures:
            future.cancel()
        raise
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
    require(durations, "parallel progress smoke completed no runs")
    elapsed = time.monotonic() - started
    print(
        f"{PARALLEL_PROGRESS_SMOKE_SCENARIO} summary: "
        f"workers={workers} runs_per_worker={runs} "
        f"elapsed={elapsed:.3f}s {format_duration_stats(durations)}",
        file=sys.stderr,
    )


def run_root_setup_matrix(repo_root, fixture_root, timeout):
    cases = [
        {
            "name": "explicit_root_ignores_advertised_roots",
            "use_root_arg": True,
            "advertise_roots": True,
            "expected_roots_requests": 0,
            "expect_success": True,
        },
        {
            "name": "missing_roots_capability",
            "use_root_arg": False,
            "advertise_roots": False,
            "expected_roots_requests": 0,
            "error_needle": "did not advertise roots",
        },
        {
            "name": "init_tool_without_roots_capability",
            "use_root_arg": False,
            "advertise_roots": False,
            "expected_roots_requests": 0,
            "init_workspace": True,
            "expect_success": True,
        },
        {
            "name": "init_tool_recovers_after_missing_roots_error",
            "use_root_arg": False,
            "advertise_roots": False,
            "expected_roots_requests": 0,
            "pre_init_sync_error": True,
            "init_workspace": True,
            "expect_success": True,
        },
        {
            "name": "empty_roots",
            "use_root_arg": False,
            "advertise_roots": True,
            "roots_payload": [],
            "expected_roots_requests": 1,
            "error_needle": "no roots",
        },
        {
            "name": "multiple_roots",
            "use_root_arg": False,
            "advertise_roots": True,
            "roots": "multiple",
            "expected_roots_requests": 1,
            "error_needle": "multiple roots",
        },
        {
            "name": "non_file_root",
            "use_root_arg": False,
            "advertise_roots": True,
            "roots_payload": [{"uri": "https://example.invalid/project", "name": "not-file"}],
            "expected_roots_requests": 1,
            "error_needle": "file://",
        },
        {
            "name": "roots_rpc_error",
            "use_root_arg": False,
            "advertise_roots": True,
            "roots_response": "error",
            "expected_roots_requests": 1,
            "error_needle": "roots/list failed",
        },
        {
            "name": "unrelated_request_during_roots",
            "use_root_arg": False,
            "advertise_roots": True,
            "roots_response": "unrelated_then_normal",
            "expected_roots_requests": 1,
            "expect_success": True,
            "extra_error_id": "during-roots",
        },
    ]
    for case in cases:
        with tempfile.TemporaryDirectory(prefix=f"lean-beam-mcp-{case['name']}-") as tmp:
            project_root = Path(tmp) / "project"
            shutil.copytree(fixture_root, project_root)
            roots = None
            if case.get("roots") == "multiple":
                extra_root = Path(tmp) / "other-project"
                extra_root.mkdir()
                roots = [project_root, extra_root]
            client = McpClient(
                repo_root,
                project_root,
                timeout,
                use_root_arg=case["use_root_arg"],
                advertise_roots=case["advertise_roots"],
                roots=roots,
                roots_payload=case.get("roots_payload"),
                roots_response=case.get("roots_response", "normal"),
                label=f"root-setup-{case['name']}",
            )
            try:
                client.initialize()
                tools = expect_result(client.request("tools/list")).get("tools")
                require(isinstance(tools, list) and tools, f"{case['name']}: tools/list should not require root setup: {tools}")
                if case.get("pre_init_sync_error"):
                    response = client.request(
                        "tools/call",
                        {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
                    )
                    expect_error_message_contains(response, -32600, "did not advertise roots")
                if case.get("init_workspace"):
                    first_init = init_workspace(client, project_root)
                    require(
                        first_init.get("runtime_reused") is False,
                        f"{case['name']}: first init should create the workspace: {first_init}",
                    )
                    second_init = init_workspace(client, project_root)
                    require(
                        second_init.get("runtime_reused") is True,
                        f"{case['name']}: second init should be idempotent: {second_init}",
                    )
                    other_root = Path(tmp) / "other-project"
                    shutil.copytree(fixture_root, other_root)
                    changed_root = client.request(
                        "tools/call",
                        {"name": "lean_init_workspace", "arguments": {"root": str(other_root)}},
                    )
                    expect_tool_error_code(changed_root, "invalidInput")
                response = client.request(
                    "tools/call",
                    {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
                )
                if case.get("expect_success"):
                    result = expect_result(response)
                    require(result.get("isError") is not True, f"{case['name']}: lean_sync returned tool error: {result}")
                else:
                    expect_error_message_contains(response, -32600, case["error_needle"])
                require_roots_requests(client, case["expected_roots_requests"], case["name"])
                if "extra_error_id" in case:
                    expect_extra_error_code(client, case["extra_error_id"], -32600, case["name"])
            finally:
                client.close()


def run_init_workspace_mode_matrix(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-init-relative-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        client = McpClient(repo_root, project_root, timeout, use_root_arg=False, label="init-relative-root")
        try:
            client.initialize()
            response = client.request(
                "tools/call",
                {"name": "lean_init_workspace", "arguments": {"root": "relative/project"}},
            )
            error = expect_tool_error_code(response, "invalidInput")
            require("absolute" in error.get("message", ""), f"relative root error should mention absolute: {error}")
        finally:
            client.close()

    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-init-non-workspace-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        empty_root = Path(tmp) / "empty"
        empty_root.mkdir()
        client = McpClient(repo_root, project_root, timeout, use_root_arg=False, label="init-non-workspace")
        try:
            client.initialize()
            response = client.request(
                "tools/call",
                {"name": "lean_init_workspace", "arguments": {"root": str(empty_root)}},
            )
            error = expect_tool_error_code(response, "invalidInput")
            require("Lean/Lake project" in error.get("message", ""), f"non-workspace error should mention Lean/Lake: {error}")
        finally:
            client.close()

    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-init-verify-empty-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        client = McpClient(repo_root, project_root, timeout, use_root_arg=False, label="init-verify-empty")
        try:
            client.initialize()
            response = client.request(
                "tools/call",
                {"name": "lean_init_workspace", "arguments": {"root": str(project_root), "mode": "verify"}},
            )
            error = expect_tool_error_code(response, "invalidInput")
            require("not initialized" in error.get("message", ""), f"verify-before-set error should mention state: {error}")
        finally:
            client.close()

    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-init-verify-reset-") as tmp:
        project_root = Path(tmp) / "project"
        other_root = Path(tmp) / "other-project"
        shutil.copytree(fixture_root, project_root)
        shutil.copytree(fixture_root, other_root)
        client = McpClient(repo_root, project_root, timeout, use_root_arg=False, label="init-verify-reset")
        try:
            client.initialize()
            first_init = init_workspace(client, project_root)
            require(first_init.get("runtime_reused") is False, f"first init should create runtime: {first_init}")
            verify = init_workspace(client, project_root, mode="verify")
            require(verify.get("runtime_reused") is True, f"verify should reuse runtime: {verify}")
            verify_other = client.request(
                "tools/call",
                {"name": "lean_init_workspace", "arguments": {"root": str(other_root), "mode": "verify"}},
            )
            expect_tool_error_code(verify_other, "invalidInput")

            reset = init_workspace(
                client,
                other_root,
                mode="reset",
                invalidated_handles=True,
                previous_root=project_root,
            )
            require(reset.get("runtime_reused") is False, f"reset should create new runtime: {reset}")
            sync = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                Path(sync.get("active_root")).resolve() == other_root.resolve(),
                f"sync after reset returned wrong active_root: {sync}",
            )
        finally:
            client.close()

    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-init-reset-after-use-") as tmp:
        project_root = Path(tmp) / "project"
        other_root = Path(tmp) / "other-project"
        shutil.copytree(fixture_root, project_root)
        shutil.copytree(fixture_root, other_root)
        client = McpClient(repo_root, project_root, timeout, use_root_arg=False, label="init-reset-after-use")
        try:
            client.initialize()
            init_workspace(client, project_root)
            sync = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                Path(sync.get("active_root")).resolve() == project_root.resolve(),
                f"bad active_root before reset: {sync}",
            )
            version = sync.get("version")
            require(isinstance(version, int), f"pre-reset sync did not return a version: {sync}")
            minted = client.call_tool(
                "lean_run_at_handle",
                {
                    "path": "PositionEmptyLine.lean",
                    "version": version,
                    "line": 1,
                    "character": 0,
                    "text": "def mcpResetBase : Nat := 1",
                },
            )
            require_success("pre-reset handle mint", minted)
            old_handle = minted.get("next_handle")
            require(
                isinstance(old_handle, dict),
                f"pre-reset handle mint did not return next_handle: {minted}",
            )

            same_root_reset = init_workspace(
                client,
                project_root,
                mode="reset",
                invalidated_handles=True,
                previous_root=project_root,
            )
            require(
                same_root_reset.get("runtime_reused") is False,
                f"same-root reset should recreate runtime: {same_root_reset}",
            )
            expect_stale_handle(client, old_handle, "same-root reset")
            sync_after_same_reset = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                Path(sync_after_same_reset.get("active_root")).resolve() == project_root.resolve(),
                f"sync after same-root reset returned wrong active_root: {sync_after_same_reset}",
            )
            same_reset_version = sync_after_same_reset.get("version")
            require(
                isinstance(same_reset_version, int),
                f"sync after same-root reset did not return a version: {sync_after_same_reset}",
            )
            reminted = client.call_tool(
                "lean_run_at_handle",
                {
                    "path": "PositionEmptyLine.lean",
                    "version": same_reset_version,
                    "line": 1,
                    "character": 0,
                    "text": "def mcpResetBase : Nat := 1",
                },
            )
            require_success("post-reset handle mint", reminted)
            current_handle = reminted.get("next_handle")
            require(
                isinstance(current_handle, dict),
                f"post-reset handle mint did not return next_handle: {reminted}",
            )

            reset = init_workspace(
                client,
                other_root,
                mode="reset",
                invalidated_handles=True,
                previous_root=project_root,
            )
            require(
                reset.get("runtime_reused") is False,
                f"reset after use should create new runtime: {reset}",
            )
            sync_after_reset = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                Path(sync_after_reset.get("active_root")).resolve() == other_root.resolve(),
                f"sync after reset returned wrong active_root: {sync_after_reset}",
            )
            expect_stale_handle(client, current_handle, "cross-root reset")
        finally:
            client.close()

    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-init-reset-stale-root-") as tmp:
        project_root = Path(tmp) / "project"
        other_root = Path(tmp) / "other-project"
        shutil.copytree(fixture_root, project_root)
        shutil.copytree(fixture_root, other_root)
        client = McpClient(repo_root, project_root, timeout, use_root_arg=False, label="init-reset-stale-root")
        try:
            client.initialize()
            init_workspace(client, project_root)
            sync = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                Path(sync.get("active_root")).resolve() == project_root.resolve(),
                f"bad active_root before stale reset: {sync}",
            )
            shutil.rmtree(project_root)
            reset = init_workspace(
                client,
                other_root,
                mode="reset",
                invalidated_handles=True,
                previous_root=project_root,
            )
            require(
                reset.get("runtime_reused") is False,
                f"stale reset should create new runtime: {reset}",
            )
            sync_after_reset = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                Path(sync_after_reset.get("active_root")).resolve() == other_root.resolve(),
                f"sync after stale reset returned wrong active_root: {sync_after_reset}",
            )
        finally:
            client.close()


def initialize_params(capabilities=None):
    return {
        "protocolVersion": SUPPORTED_PROTOCOL_VERSION,
        "capabilities": capabilities if capabilities is not None else {},
        "clientInfo": {"name": "lean-beam-mcp-lifecycle-test", "version": "0"},
    }


def check_response(response, expectation, label):
    kind = expectation["kind"]
    if kind == "result":
        expect_result(response)
    elif kind == "error":
        error = expect_error_code(response, expectation["code"])
        needle = expectation.get("message_contains")
        if needle is not None:
            message = error.get("message")
            require(isinstance(message, str) and needle in message, f"{label}: expected {needle!r} in {response}")
    else:
        fail(f"{label}: unknown expectation kind {kind}")


def run_lifecycle_matrix(repo_root, fixture_root, timeout):
    cases = [
        {
            "name": "ping_before_initialize",
            "actions": [
                {"request": "ping", "expect": {"kind": "result"}},
            ],
        },
        {
            "name": "shutdown_before_initialize",
            "actions": [
                {"request": "shutdown", "expect": {"kind": "result"}, "stops": True},
            ],
        },
        {
            "name": "tool_call_before_initialize",
            "actions": [
                {
                    "request": "tools/call",
                    "params": {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
                    "expect": {"kind": "error", "code": -32600, "message_contains": "initialize"},
                },
            ],
        },
        {
            "name": "tool_call_before_initialized_notification",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {
                    "request": "tools/call",
                    "params": {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
                    "expect": {"kind": "error", "code": -32600, "message_contains": "notifications/initialized"},
                },
            ],
        },
        {
            "name": "repeat_initialize",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {
                    "request": "initialize",
                    "params": initialize_params(),
                    "expect": {"kind": "error", "code": -32600, "message_contains": "already completed"},
                },
            ],
        },
        {
            "name": "initialized_before_initialize_does_not_ready_server",
            "actions": [
                {"notify": "notifications/initialized"},
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {
                    "request": "tools/list",
                    "expect": {"kind": "error", "code": -32600, "message_contains": "notifications/initialized"},
                },
            ],
        },
        {
            "name": "unknown_method_before_initialize",
            "actions": [
                {"request": "unknown/method", "expect": {"kind": "error", "code": -32600, "message_contains": "initialize"}},
            ],
        },
        {
            "name": "unknown_method_after_initialize",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {"notify": "notifications/initialized"},
                {"request": "unknown/method", "expect": {"kind": "error", "code": -32601}},
            ],
        },
    ]
    for case in cases:
        with tempfile.TemporaryDirectory(prefix=f"lean-beam-mcp-{case['name']}-") as tmp:
            project_root = Path(tmp) / "project"
            shutil.copytree(fixture_root, project_root)
            client = McpClient(repo_root, project_root, timeout, label=f"lifecycle-{case['name']}")
            stopped = False
            try:
                for action in case["actions"]:
                    if "notify" in action:
                        client.notify(action["notify"], action.get("params"))
                        continue
                    response = client.request(action["request"], action.get("params"))
                    check_response(response, action["expect"], f"{case['name']} {action['request']}")
                    if action.get("stops"):
                        stopped = True
                        break
                require_roots_requests(client, 0, case["name"])
            finally:
                if stopped and client.proc.stdin and not client.proc.stdin.closed:
                    client.proc.stdin.close()
                    try:
                        client.proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
                client.close()


def run_closed_stdout_regression(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-closed-stdout-") as tmp:
        project_root = Path(tmp) / "project"
        shutil.copytree(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label="closed-stdout-regression",
            drain_stdout=False,
        )
        stderr = ""
        try:
            client.proc.stdout.close()
            client.send_message(
                {
                    "jsonrpc": "2.0",
                    "id": "closed-stdout",
                    "method": "initialize",
                    "params": initialize_params(),
                }
            )
            client.proc.stdin.close()
            try:
                client.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.proc.kill()
                fail("lean-beam-mcp did not exit after stdout was closed")
            client.stderr_thread.join(timeout=1)
            stderr = "\n".join(client.stderr_lines)
            require(client.proc.returncode == 0, f"lean-beam-mcp exited with {client.proc.returncode}\n{stderr}")
            if client.server_trace:
                unexpected = [
                    line for line in stderr.splitlines()
                    if not line.startswith("lean-beam-mcp trace ")
                ]
                require(
                    not unexpected,
                    "lean-beam-mcp wrote unexpected non-trace stderr after closed stdout:\n"
                    + "\n".join(unexpected),
                )
            else:
                require(stderr.strip() == "", f"lean-beam-mcp wrote unexpected stderr after closed stdout:\n{stderr}")
        finally:
            if client.proc.poll() is None:
                client.proc.kill()
                client.proc.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description="Exercise lean-beam-mcp over stdio.")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--restart-cycles", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--scenario",
        choices=["full", PARALLEL_PROGRESS_SMOKE_SCENARIO] + sorted(FOCUSED_SYNC_SCENARIOS),
        default="full",
        help="run the full smoke suite or a focused repro scenario",
    )
    parser.add_argument(
        "--repro-runs",
        type=int,
        default=1,
        help="number of focused scenario repetitions",
    )
    parser.add_argument(
        "--parallel-workers",
        type=int,
        default=8,
        help="number of workers for the progress-smoke-parallel repro scenario",
    )
    parser.add_argument(
        "--slow-threshold",
        type=float,
        default=None,
        help="only print per-run focused scenario timings at or above this many seconds",
    )
    parser.add_argument(
        "--server-trace",
        action="store_true",
        help="enable opt-in lean-beam-mcp and broker stderr trace output",
    )
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_root = repo_root / "tests" / "save_olean_project"
    require(fixture_root.exists(), f"missing MCP fixture root at {fixture_root}")
    if args.scenario in FOCUSED_SYNC_SCENARIOS:
        run_focused_sync_repro(
            repo_root,
            fixture_root,
            args.timeout,
            args.repro_runs,
            args.slow_threshold,
            args.scenario,
            args.server_trace,
        )
        return
    if args.scenario == PARALLEL_PROGRESS_SMOKE_SCENARIO:
        run_parallel_progress_smoke_repro(
            repo_root,
            fixture_root,
            args.timeout,
            args.repro_runs,
            args.parallel_workers,
            args.slow_threshold,
            args.server_trace,
        )
        return
    for cycle in range(args.restart_cycles):
        run_cycle(repo_root, fixture_root, cycle, args.iterations, args.timeout)
        run_cycle(
            repo_root,
            fixture_root,
            f"Roots{cycle}",
            1,
            args.timeout,
            use_root_arg=False,
            advertise_roots=True,
            expected_roots_requests=1,
        )
    run_relative_root_arg(repo_root, fixture_root, args.timeout)
    run_diagnostic_logging(repo_root, fixture_root, args.timeout)
    run_progress_notification_smoke(repo_root, fixture_root, args.timeout)
    run_root_setup_matrix(repo_root, fixture_root, args.timeout)
    run_init_workspace_mode_matrix(repo_root, fixture_root, args.timeout)
    run_lifecycle_matrix(repo_root, fixture_root, args.timeout)
    run_closed_stdout_regression(repo_root, fixture_root, args.timeout)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"test-mcp-stdio.py: {err}", file=sys.stderr)
        sys.exit(1)
