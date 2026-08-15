#!/usr/bin/env python3

import platform


MCP_LEGACY_PROTOCOL_VERSION = "2025-11-25"
MCP_MODERN_PROTOCOL_VERSION = "2026-07-28"
MCP_PUBLIC_CACHE_TTL_MS = 60 * 60 * 1000


def fail(message):
    raise RuntimeError(message)


def require(condition, message):
    if not condition:
        fail(message)


def notifications_by_method(notifications, method):
    return [notification for notification in notifications if notification.get("method") == method]


def notification_params(notification, method, label):
    require(
        notification.get("method") == method,
        f"{label}: unexpected notification method: {notification}",
    )
    params = notification.get("params")
    require(isinstance(params, dict), f"{label}: notification missing params: {notification}")
    return params


def progress_messages(notifications):
    return [
        notification_params(notification, "notifications/progress", "progress notification").get("message")
        for notification in notifications
    ]


def require_document_progress_range(structured, label):
    progress = structured.get("document_progress")
    require(isinstance(progress, dict), f"{label}: missing document_progress metadata: {structured}")
    updates = progress.get("updates")
    require(
        type(updates) is int and updates >= 0,
        f"{label}: invalid document_progress updates: {progress}",
    )
    done = progress.get("done")
    require(type(done) is bool, f"{label}: invalid document_progress done: {progress}")
    require("line" not in progress, f"{label}: document_progress should not expose line: {progress}")
    require("totalLines" not in progress, f"{label}: document_progress should not expose totalLines: {progress}")
    range_end = progress.get("range_end_line")
    if range_end is not None:
        require(
            type(range_end) is int and range_end >= 1,
            f"{label}: invalid document_progress range_end_line: {progress}",
        )
    range_start = progress.get("range_start_line")
    if range_start is not None:
        require(
            type(range_start) is int
            and range_start >= 1
            and (range_end is None or range_start <= range_end),
            f"{label}: invalid document_progress range_start_line: {progress}",
        )


def save_warning_text(marker):
    return "\n".join(
        [
            "def bVal : Nat := 1",
            "",
            "set_option linter.unusedVariables true in",
            "theorem warnOnly (n : Nat) : True := by",
            "  trivial",
            "",
            marker,
        ]
    ) + "\n"


def shared_lib_name():
    system = platform.system()
    if system == "Darwin":
        return "libbeam_Beam_LSP.dylib"
    if system.startswith("Windows") or system in {"MSYS_NT", "MINGW_NT"}:
        return "beam_Beam_LSP.dll"
    return "libbeam_Beam_LSP.so"
