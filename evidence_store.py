#!/usr/bin/env python3
"""Local evidence capture for lock events."""

from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path
from typing import Any

from runtime_paths import RuntimePaths
from state_store import now_iso


PROJECT_DIR = Path(__file__).resolve().parent
EVIDENCE_DIR = RuntimePaths.for_source(PROJECT_DIR).evidence_dir
SCREENSHOT_COMMAND = "/usr/sbin/screencapture"


def _safe_token(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-") or "unknown"


def capture_screen_evidence(
    reason: str,
    evidence_dir: Path = EVIDENCE_DIR,
) -> Path:
    if not Path(SCREENSHOT_COMMAND).exists():
        raise FileNotFoundError(f"Screenshot command not found: {SCREENSHOT_COMMAND}")
    evidence_dir.mkdir(parents=True, exist_ok=True)
    timestamp = _safe_token(now_iso())
    filename = f"{timestamp}-{_safe_token(reason)}-screen.png"
    output_path = evidence_dir / filename
    subprocess.run([SCREENSHOT_COMMAND, "-x", str(output_path)], check=True)
    return output_path


def _load_cv2() -> Any:
    try:
        import cv2  # type: ignore
    except ImportError as exc:
        raise RuntimeError("Missing OpenCV dependency. Run scripts/bootstrap.sh first.") from exc
    return cv2


def capture_camera_evidence(
    reason: str,
    camera_index: int = 0,
    evidence_dir: Path = EVIDENCE_DIR,
) -> Path:
    cv2 = _load_cv2()
    evidence_dir.mkdir(parents=True, exist_ok=True)
    timestamp = _safe_token(now_iso())
    filename = f"{timestamp}-{_safe_token(reason)}-camera.jpg"
    output_path = evidence_dir / filename

    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        raise RuntimeError(f"Could not open camera index {camera_index}")

    frame = None
    try:
        for _ in range(8):
            ok, candidate = cap.read()
            if ok:
                frame = candidate
            time.sleep(0.08)
    finally:
        cap.release()

    if frame is None:
        raise RuntimeError("Could not capture camera evidence frame")

    ok = cv2.imwrite(str(output_path), frame)
    if not ok:
        raise RuntimeError(f"Could not write camera evidence: {output_path}")
    return output_path
