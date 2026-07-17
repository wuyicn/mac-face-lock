#!/usr/bin/env python3
"""Capture the owner's local face profile."""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

from face_verifier import capture_owner_profile
from runtime_paths import RuntimePaths
from state_store import write_state


PROJECT_DIR = Path(__file__).resolve().parent
RUNTIME_PATHS = RuntimePaths.for_source(PROJECT_DIR)
CONFIG_PATH = RUNTIME_PATHS.config_path


def enroll_owner(
    paths: RuntimePaths,
    progress: Callable[[int, int], None] | None = None,
) -> Path:
    paths.ensure_writable_directories()
    config = json.loads(paths.config_path.read_text(encoding="utf-8"))
    output_path = capture_owner_profile(
        config,
        paths.owner_face_path,
        progress=progress,
    )
    write_state(
        {"status": "owner_enrolled", "owner_profile": str(output_path)},
        path=paths.state_path,
    )
    return output_path


def main(paths: RuntimePaths = RUNTIME_PATHS) -> int:
    print("准备录入本人脸部特征。请保持光线稳定，并在录入过程中缓慢切换几个角度：")
    print("正脸、左偏约30度、右偏约30度、轻微低头、轻微抬头。")
    output_path = enroll_owner(paths)
    print(f"本人特征已保存：{output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
