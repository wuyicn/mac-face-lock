#!/usr/bin/env python3
"""Tests for optional external lock notifications."""

from __future__ import annotations

import unittest
from unittest import mock

from event_notifier import notify_lock_event


class EventNotifierTests(unittest.TestCase):
    def test_enabled_notification_requires_configured_script(self) -> None:
        with self.assertRaisesRegex(ValueError, "event_notify_script"):
            notify_lock_event(
                {"event_notify_on_lock": True, "event_notify_script": ""},
                "stranger",
                None,
            )

    def test_disabled_notification_never_runs_subprocess(self) -> None:
        with mock.patch("event_notifier.subprocess.run") as run:
            result = notify_lock_event(
                {"event_notify_on_lock": False},
                "stranger",
                None,
            )

        self.assertIsNone(result)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
