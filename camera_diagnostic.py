#!/usr/bin/env python3
"""Capture one camera frame with face-detection guide overlays."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
import time

from face_verifier import _detect_face_boxes, _face_cascades, _load_runtime_modules


PROJECT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = PROJECT_DIR / "data" / "evidence"


def main() -> int:
    cv2 = _load_runtime_modules()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    output_path = OUTPUT_DIR / f"camera-diagnostic-{datetime.now().strftime('%Y-%m-%dT%H-%M-%S')}.png"

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
