import json
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from activity_store import append_activity


class ActivityStoreTests(unittest.TestCase):
    def test_explicit_values_and_utf8_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "activity.jsonl"
            metadata = {
                "owner_hits": 2,
                "stranger_hits": 0,
                "frames_checked": 2,
            }

            event = append_activity(
                "owner_verified",
                "已确认本人",
                "达到本人识别阈值，继续使用",
                "success",
                metadata,
                path=path,
                event_id="event-1",
                timestamp="2026-07-14T13:48:00+08:00",
            )

            self.assertEqual(event["schema_version"], 1)
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), event)
            self.assertEqual(event["id"], "event-1")
            self.assertEqual(event["timestamp"], "2026-07-14T13:48:00+08:00")
            self.assertEqual(event["title"], "已确认本人")
            self.assertEqual(event["detail"], "达到本人识别阈值，继续使用")
            self.assertEqual(event["metadata"], metadata)

    @patch("activity_store.now_iso", return_value="2026-07-14T05:48:00+00:00")
    @patch("activity_store.uuid.uuid4", return_value=uuid.UUID(int=1))
    def test_generates_default_timestamp_and_uuid(
        self,
        mocked_uuid: unittest.mock.Mock,
        mocked_now_iso: unittest.mock.Mock,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "activity.jsonl"

            event = append_activity(
                "monitor_started",
                "监控已启动",
                "开始检测摄像头画面",
                "info",
                path=path,
            )

            self.assertEqual(event["id"], "00000000-0000-0000-0000-000000000001")
            self.assertEqual(event["timestamp"], "2026-07-14T05:48:00+00:00")
            self.assertEqual(event["metadata"], {})
            mocked_uuid.assert_called_once_with()
            mocked_now_iso.assert_called_once_with()

    def test_preserves_nested_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested" / "activity.jsonl"
            metadata = {
                "counts": {"owner": 2, "stranger": 0},
                "labels": ["本人", "可信"],
                "enabled": True,
            }

            event = append_activity(
                "owner_verified",
                "已确认本人",
                "识别完成",
                "success",
                metadata,
                path=path,
            )

            self.assertEqual(event["metadata"], metadata)
            self.assertEqual(
                json.loads(path.read_text(encoding="utf-8"))["metadata"],
                metadata,
            )

    def test_appends_one_json_object_per_line(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "activity.jsonl"

            first = append_activity(
                "monitor_started",
                "监控已启动",
                "第一条记录",
                "info",
                path=path,
                event_id="event-1",
                timestamp="2026-07-14T13:48:00+08:00",
            )
            second = append_activity(
                "monitor_stopped",
                "监控已停止",
                "第二条记录",
                "warning",
                path=path,
                event_id="event-2",
                timestamp="2026-07-14T13:49:00+08:00",
            )

            lines = path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 2)
            self.assertEqual([json.loads(line) for line in lines], [first, second])


if __name__ == "__main__":
    unittest.main()
