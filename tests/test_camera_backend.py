from __future__ import annotations

import ast
import importlib
import unittest
from pathlib import Path
from unittest.mock import patch


PROJECT_DIR = Path(__file__).resolve().parents[1]
CAMERA_BACKEND = PROJECT_DIR / "camera_backend.py"
PRODUCTION_CAMERA_PATHS = {
    "camera_diagnostic.py": 2,
    "evidence_store.py": 1,
    "face_verifier.py": 2,
}


class RecordingCV2:
    CAP_AVFOUNDATION = 1_200

    def __init__(self) -> None:
        self.calls: list[tuple[object, ...]] = []
        self.capture = object()

    def VideoCapture(self, *arguments: object) -> object:
        self.calls.append(arguments)
        return self.capture


class CameraBackendTests(unittest.TestCase):
    def load_backend(self):
        self.assertTrue(
            CAMERA_BACKEND.is_file(),
            "camera_backend.py must provide the shared camera opener",
        )
        importlib.invalidate_caches()
        return importlib.import_module("camera_backend")

    def test_macos_uses_avfoundation_backend(self) -> None:
        backend = self.load_backend()
        cv2 = RecordingCV2()

        with patch("camera_backend.sys.platform", "darwin"):
            capture = backend.open_camera(cv2, 4)

        self.assertIs(capture, cv2.capture)
        self.assertEqual(cv2.calls, [(4, cv2.CAP_AVFOUNDATION)])

    def test_non_macos_preserves_default_backend_selection(self) -> None:
        backend = self.load_backend()
        cv2 = RecordingCV2()

        with patch("camera_backend.sys.platform", "linux"):
            capture = backend.open_camera(cv2, 2)

        self.assertIs(capture, cv2.capture)
        self.assertEqual(cv2.calls, [(2,)])

    def test_every_production_camera_open_routes_through_shared_helper(self) -> None:
        for relative_path, expected_calls in PRODUCTION_CAMERA_PATHS.items():
            with self.subTest(path=relative_path):
                tree = ast.parse(
                    (PROJECT_DIR / relative_path).read_text(encoding="utf-8")
                )
                direct_opens = [
                    node
                    for node in ast.walk(tree)
                    if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "VideoCapture"
                ]
                helper_opens = [
                    node
                    for node in ast.walk(tree)
                    if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Name)
                    and node.func.id == "open_camera"
                ]

                self.assertEqual(
                    direct_opens,
                    [],
                    f"{relative_path} bypasses the shared camera opener",
                )
                self.assertEqual(len(helper_opens), expected_calls)


if __name__ == "__main__":
    unittest.main()
