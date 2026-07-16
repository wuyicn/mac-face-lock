#!/usr/bin/env python3
"""Capture the owner's local face profile."""

from __future__ import annotations

import json
from pathlib import Path

from face_verifier import capture_owner_profile
from state_store import write_state


PROJECT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = PROJECT_DIR / "config" / "config.json"


def main() -> int:
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    print("准备录入本人脸部特征。请保持光线稳定，并在录入过程中缓慢切换几个角度：")
    print("正脸、左偏约30度、右偏约30度、轻微低头、轻微抬头。")
    output_path = capture_owner_profile(config)
    write_state({"status": "owner_enrolled", "owner_profile": str(output_path)})
    print(f"本人特征已保存：{output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
