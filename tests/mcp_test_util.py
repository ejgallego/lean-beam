#!/usr/bin/env python3

import platform


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


def require_file_progress_line(structured, label):
    progress = structured.get("file_progress")
    require(isinstance(progress, dict), f"{label}: missing file_progress metadata: {structured}")
    line = progress.get("line")
    total = progress.get("totalLines")
    require(type(line) is int and line >= 1, f"{label}: invalid file_progress line: {progress}")
    require(type(total) is int and total >= line, f"{label}: invalid file_progress totalLines: {progress}")


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
        return "librunAt_RunAt.dylib"
    if system.startswith("Windows") or system in {"MSYS_NT", "MINGW_NT"}:
        return "runAt_RunAt.dll"
    return "librunAt_RunAt.so"
