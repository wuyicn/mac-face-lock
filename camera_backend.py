"""Platform-specific OpenCV camera opening."""

from __future__ import annotations

import sys
from typing import Any


def open_camera(cv2: Any, camera_index: int) -> Any:
    if sys.platform == "darwin":
        return cv2.VideoCapture(camera_index, cv2.CAP_AVFOUNDATION)
    return cv2.VideoCapture(camera_index)
