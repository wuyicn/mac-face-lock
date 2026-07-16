import json
import tempfile
import unittest
from pathlib import Path

from control_store import ControlState, read_control, write_control


class ControlStoreTests(unittest.TestCase):
    def test_missing_file_uses_enabled_default(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            self.assertEqual(read_control(path), ControlState(True, None))

    def test_round_trip_false(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            written = write_control(False, path)
            self.assertFalse(written.protection_enabled)
            self.assertEqual(read_control(path), written)
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload["schema_version"], 1)

    def test_invalid_file_uses_supplied_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text("{broken", encoding="utf-8")
            fallback = ControlState(False, "previous")
            self.assertEqual(read_control(path, fallback), fallback)

    def test_non_boolean_enabled_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text('{"protection_enabled": "no"}', encoding="utf-8")
            fallback = ControlState(True, None)
            self.assertEqual(read_control(path, fallback), fallback)

    def test_non_object_file_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text("[]", encoding="utf-8")
            fallback = ControlState(False, "previous")
            self.assertEqual(read_control(path, fallback), fallback)

    def test_missing_schema_version_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text('{"protection_enabled": true}', encoding="utf-8")
            fallback = ControlState(False, "previous")
            self.assertEqual(read_control(path, fallback), fallback)

    def test_unsupported_schema_version_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text(
                '{"schema_version": 2, "protection_enabled": true}',
                encoding="utf-8",
            )
            fallback = ControlState(False, "previous")
            self.assertEqual(read_control(path, fallback), fallback)

    def test_boolean_schema_version_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text(
                '{"schema_version": true, "protection_enabled": true}',
                encoding="utf-8",
            )
            fallback = ControlState(False, "previous")
            self.assertEqual(read_control(path, fallback), fallback)

    def test_float_schema_version_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text(
                '{"schema_version": 1.0, "protection_enabled": true}',
                encoding="utf-8",
            )
            fallback = ControlState(False, "previous")
            self.assertEqual(read_control(path, fallback), fallback)


if __name__ == "__main__":
    unittest.main()
