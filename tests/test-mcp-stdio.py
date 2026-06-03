#!/usr/bin/env python3

import argparse
import json
import platform
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SUPPORTED_PROTOCOL_VERSION = "2025-11-25"


def fail(message):
    raise RuntimeError(message)


def require(condition, message):
    if not condition:
        fail(message)


def shared_lib_name():
    system = platform.system()
    if system == "Darwin":
        return "librunAt_RunAt.dylib"
    if system.startswith("Windows") or system in {"MSYS_NT", "MINGW_NT"}:
        return "runAt_RunAt.dll"
    return "librunAt_RunAt.so"


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
    ):
        self.repo_root = repo_root
        self.project_root = project_root
        self.timeout = timeout
        self.next_id = 0
        self.advertise_roots = advertise_roots
        self.roots = [Path(root) for root in (roots if roots is not None else [project_root])]
        self.roots_payload = roots_payload
        self.roots_response = roots_response
        self.roots_request_count = 0
        self.pending_extra_response_ids = set()
        self.extra_responses = []
        exe = repo_root / ".lake" / "build" / "bin" / "lean-beam-mcp"
        plugin = repo_root / ".lake" / "build" / "lib" / shared_lib_name()
        lean_cmd = shutil.which("lean") or "lean"
        require(exe.exists(), f"missing lean-beam-mcp executable at {exe}")
        require(plugin.exists(), f"missing runAt plugin shared library at {plugin}")
        cmd = [str(exe)]
        if use_root_arg:
            cmd.extend(["--root", str(project_root)])
        cmd.extend(
            [
                "--lean-cmd",
                lean_cmd,
                "--lean-plugin",
                str(plugin),
            ]
        )
        self.proc = subprocess.Popen(
            cmd,
            cwd=str(repo_root),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )

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
        stderr = self.proc.stderr.read()
        require(stderr.strip() == "", f"lean-beam-mcp wrote unexpected stderr:\n{stderr}")

    def send_message(self, message):
        require(self.proc.poll() is None, "lean-beam-mcp exited before request")
        line = json.dumps(message, separators=(",", ":"))
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def handle_server_request(self, request):
        method = request.get("method")
        request_id = request.get("id")
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

    def read_response(self, expected_id):
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(f"timed out waiting for MCP response id {expected_id}")
            if self.proc.poll() is not None:
                stderr = self.proc.stderr.read()
                fail(f"lean-beam-mcp exited early with code {self.proc.returncode}\n{stderr}")
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if line == "":
                fail(f"lean-beam-mcp closed stdout before response id {expected_id}")
            try:
                response = json.loads(line)
            except json.JSONDecodeError as err:
                fail(f"stdout line is not valid JSON: {err}: {line!r}")
            require(response.get("jsonrpc") == "2.0", f"bad JSON-RPC response: {response}")
            if "method" in response and "id" in response:
                self.handle_server_request(response)
                continue
            if response.get("id") in self.pending_extra_response_ids:
                self.extra_responses.append(response)
                self.pending_extra_response_ids.remove(response.get("id"))
                continue
            require(response.get("id") == expected_id, f"expected response id {expected_id}, got {response}")
            return response

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send_message(message)
        return self.read_response(self.next_id)

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
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


def run_iteration(client, suffix):
    sync = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
    progress = sync.get("file_progress")
    require(isinstance(progress, dict), f"sync did not return file_progress: {sync}")

    probe = client.call_tool(
        "lean_run_at",
        {
            "path": "PositionEmptyLine.lean",
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

    goals_prev = client.call_tool(
        "lean_goals_prev",
        {"path": "GoalSmoke.lean", "line": 1, "character": 2},
    )
    prev_goals = goals_prev.get("goals")
    require(isinstance(prev_goals, list) and prev_goals, f"goals-prev returned no goals: {goals_prev}")
    require(prev_goals[0].get("target") == "True", f"goals-prev returned unexpected goal: {goals_prev}")

    goals_after = client.call_tool(
        "lean_goals_after",
        {"path": "GoalSmoke.lean", "line": 1, "character": 2},
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
            require("lean_run_at" in names, f"tools/list missing lean_run_at: {tools}")
            require("$/lean/runAt" not in names, f"tools/list exposed raw LSP method: {tools}")
            require("lean_request_at" not in names, f"tools/list exposed raw request escape hatch: {tools}")

            for iteration in range(iterations):
                run_iteration(client, f"Cycle{cycle}Iter{iteration}")
            require_roots_requests(client, expected_roots_requests, f"cycle {cycle}")
        finally:
            client.close()


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
            )
            try:
                client.initialize()
                tools = expect_result(client.request("tools/list")).get("tools")
                require(isinstance(tools, list) and tools, f"{case['name']}: tools/list should not require root setup: {tools}")
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
            client = McpClient(repo_root, project_root, timeout)
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


def main():
    parser = argparse.ArgumentParser(description="Exercise lean-beam-mcp over stdio.")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--restart-cycles", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_root = repo_root / "tests" / "save_olean_project"
    require(fixture_root.exists(), f"missing MCP fixture root at {fixture_root}")
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
    run_root_setup_matrix(repo_root, fixture_root, args.timeout)
    run_lifecycle_matrix(repo_root, fixture_root, args.timeout)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"test-mcp-stdio.py: {err}", file=sys.stderr)
        sys.exit(1)
