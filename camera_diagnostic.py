#!/usr/bin/env python3
"""Capture one camera frame with face-detection guide overlays."""

from __future__ import annotations

import json
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import time
from typing import Any

import numpy as np

from face_verifier import (
    CameraUnavailableError,
    _detect_face_boxes,
    _face_cascades,
    _load_runtime_modules,
)
from runtime_paths import RuntimePaths
from template_store import validate_owner_template


PROJECT_DIR = Path(__file__).resolve().parent
RUNTIME_PATHS = RuntimePaths.for_source(PROJECT_DIR)
OUTPUT_DIR = RUNTIME_PATHS.evidence_dir


@dataclass(frozen=True)
class DiagnosticResult:
    check: str
    status: str
    message: str
    fields: dict[str, object]


class RuntimeDiagnosticProbe:
    def check_runtime_imports(self) -> dict[str, object]:
        cv2 = _load_runtime_modules()
        import numpy

        return {
            "opencv_version": str(cv2.__version__),
            "numpy_version": str(numpy.__version__),
        }

    def check_support_directory(self, paths: RuntimePaths) -> dict[str, object]:
        paths.ensure_writable_directories()
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                dir=paths.support_dir,
                prefix=".runtime-write-",
                delete=False,
            ) as handle:
                temporary_path = Path(handle.name)
                handle.write(b"ok")
            if temporary_path.read_bytes() != b"ok":
                raise OSError("Support-directory write verification failed")
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink()
                except FileNotFoundError:
                    pass
        return {"support_dir": str(paths.support_dir)}

    def check_camera(self, config: dict[str, Any]) -> dict[str, object]:
        cv2 = _load_runtime_modules()
        camera_index = int(config.get("camera_index", 0))
        cap = cv2.VideoCapture(camera_index)
        if not cap.isOpened():
            raise CameraUnavailableError(
                f"Could not open camera index {camera_index}"
            )
        try:
            ok, frame = cap.read()
        finally:
            cap.release()
        if not ok or frame is None:
            raise CameraUnavailableError(
                f"Could not read camera index {camera_index}"
            )
        return {
            "camera_index": camera_index,
            "frame_width": int(frame.shape[1]),
            "frame_height": int(frame.shape[0]),
        }

    def check_template(self, template_path: Path) -> dict[str, object]:
        templates = np.load(template_path, allow_pickle=False)
        validate_owner_template(templates)
        return {
            "template_path": str(template_path),
            "sample_count": int(templates.shape[0]),
        }


def run_diagnostics(
    paths: RuntimePaths,
    probe: Any | None = None,
) -> list[DiagnosticResult]:
    selected_probe = probe if probe is not None else RuntimeDiagnosticProbe()
    try:
        config = json.loads(paths.config_path.read_text(encoding="utf-8"))
    except Exception as exc:
        config: dict[str, Any] = {}
        config_error = exc
    else:
        config_error = None

    checks = (
        ("runtime_imports", selected_probe.check_runtime_imports),
        (
            "support_directory",
            lambda: selected_probe.check_support_directory(paths),
        ),
        ("camera", lambda: _check_camera(selected_probe, config, config_error)),
        (
            "template",
            lambda: selected_probe.check_template(paths.owner_face_path),
        ),
    )
    results: list[DiagnosticResult] = []
    for check, operation in checks:
        try:
            fields = operation()
        except Exception as exc:
            error_fields: dict[str, object] = {
                "error_type": type(exc).__name__,
            }
            if check == "camera" and config_error is not None:
                error_fields["failure_kind"] = "runtime"
            results.append(
                DiagnosticResult(
                    check=check,
                    status="error",
                    message=str(exc),
                    fields=error_fields,
                )
            )
        else:
            results.append(
                DiagnosticResult(
                    check=check,
                    status="success",
                    message=f"{check} check passed",
                    fields=dict(fields),
                )
            )
    return results


def _check_camera(
    probe: Any,
    config: dict[str, Any],
    config_error: Exception | None,
) -> dict[str, object]:
    if config_error is not None:
        raise config_error
    return dict(probe.check_camera(config))


def main(paths: RuntimePaths = RUNTIME_PATHS) -> int:
    cv2 = _load_runtime_modules()
    paths.evidence_dir.mkdir(parents=True, exist_ok=True)
    output_path = paths.evidence_dir / f"camera-diagnostic-{datetime.now().strftime('%Y-%m-%dT%H-%M-%S')}.png"

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        raise RuntimeError("摄像头打开失败。请确认 Terminal 已允许摄像头权限，且没有其它应用占用摄像头。")

    frame = None
    try:
        for _ in range(10):
            ok, candidate = cap.read()
            if ok:
                frame = candidate
            time.sleep(0.08)
    finally:
        cap.release()

    if frame is None:
        raise RuntimeError("摄像头画面读取失败。")

    height, width = frame.shape[:2]
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    cascades = _face_cascades(cv2, {"use_profile_face_detector": True})
    boxes = _detect_face_boxes(cv2, cascades, gray)

    zone_left = int(width * 0.25)
    zone_top = int(height * 0.12)
    zone_right = int(width * 0.75)
    zone_bottom = int(height * 0.72)
    cv2.rectangle(frame, (zone_left, zone_top), (zone_right, zone_bottom), (255, 200, 0), 3)
    cv2.putText(
        frame,
        "recommended face area",
        (zone_left, max(30, zone_top - 12)),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.8,
        (255, 200, 0),
        2,
        cv2.LINE_AA,
    )

    cv2.line(frame, (width // 2, 0), (width // 2, height), (120, 120, 120), 1)
    cv2.line(frame, (0, height // 2), (width, height // 2), (120, 120, 120), 1)

    for index, (x, y, face_width, face_height) in enumerate(boxes, 1):
        cv2.rectangle(frame, (x, y), (x + face_width, y + face_height), (0, 255, 0), 3)
        cv2.putText(
            frame,
            f"face {index} {face_width}x{face_height}",
            (x, max(30, y - 10)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.75,
            (0, 255, 0),
            2,
            cv2.LINE_AA,
        )

    status = f"detected_faces={len(boxes)} frame={width}x{height}"
    cv2.putText(frame, status, (20, height - 24), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 3, cv2.LINE_AA)
    cv2.putText(frame, status, (20, height - 24), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 1, cv2.LINE_AA)

    cv2.imwrite(str(output_path), frame)
    print(f"诊断截图已保存：{output_path}")
    print(status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
