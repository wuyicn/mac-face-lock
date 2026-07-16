#!/usr/bin/env python3
"""Write lock notifications to the local event notification layer."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

from state_store import now_iso


DEFAULT_SOURCE = "mac-face-lock-agent"


def _event_script(config: dict[str, Any]) -> str:
    value = str(config.get("event_notify_script", "")).strip()
    if not value:
        raise ValueError(
            "event_notify_script is required when lock notifications are enabled"
        )
    path = Path(value).expanduser()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError(f"event_notify_script is not executable: {path}")
    return str(path.resolve())


def _run_add_event(args: list[str], timeout_seconds: float) -> dict[str, Any]:
    env = os.environ.copy()
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
        env=env,
    )
    output = "\n".join(part for part in [result.stdout.strip(), result.stderr.strip()] if part)
    if result.returncode != 0:
        raise RuntimeError(output or f"event notification command failed with exit code {result.returncode}")
    event_path = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    return {"ok": True, "event_path": event_path}


def notify_lock_event(config: dict[str, Any], reason: str, evidence_path: Path | None) -> dict[str, Any] | None:
    if not bool(config.get("event_notify_on_lock", False)):
        return None

    timeout_seconds = float(config.get("event_notify_timeout_seconds", 10))
    title = str(config.get("event_notify_title", "Mac 非本人使用提醒"))
    level = str(config.get("event_notify_level", "critical"))
    source = str(config.get("event_notify_source", DEFAULT_SOURCE))

    evidence_text = str(evidence_path.expanduser().resolve()) if evidence_path else "无"
    body = (
        f"时间：{now_iso()}\n"
        f"原因：{reason}\n"
        f"动作：已触发锁屏\n"
        f"证据图片：{evidence_text}"
    )
    command = [
        _event_script(config),
        "--title",
        title,
        "--level",
        level,
        "--body",
        body,
        "--source",
        source,
    ]
    if evidence_path is not None:
        command.extend(["--media-path", evidence_text])
    dedupe_key = str(config.get("event_notify_dedupe_key", "")).strip()
    if dedupe_key:
        command.extend(["--dedupe-key", dedupe_key])
    return _run_add_event(command, timeout_seconds)
