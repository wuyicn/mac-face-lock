#!/usr/bin/env python3
"""Lightweight smoke tests for project configuration."""

from __future__ import annotations

import json
import plistlib
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
CONFIG_PATH = PROJECT_DIR / "config" / "config.json"


class ConfigurationTests(unittest.TestCase):
    def test_default_config_disables_external_notifications(self) -> None:
        config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))

        self.assertIs(config["event_notify_on_lock"], False)
        self.assertEqual(config["event_notify_script"], "")

    def test_config_loads(self) -> None:
        config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        self.assertIn(config["mode"], {"observe", "balanced", "strict", "presence_guard"})
        self.assertGreater(config["verify_window_seconds"], 0)
        self.assertGreater(config["frame_interval_seconds"], 0)
        self.assertGreater(config["idle_seconds_before_armed"], 0)
        self.assertIsInstance(config["system_idle_poll_enabled"], bool)
        self.assertGreater(config["system_idle_trigger_seconds"], 0)
        self.assertIsInstance(config["capture_screen_on_lock"], bool)
        self.assertIsInstance(config["use_profile_face_detector"], bool)
        self.assertIs(config["lock_on_camera_error"], False)
        self.assertGreaterEqual(config["cooldown_seconds_after_lock"], 300)
        self.assertGreaterEqual(config["camera_error_cooldown_seconds"], 300)
        self.assertIn(config["event_notify_level"], {"info", "warning", "critical"})
        self.assertIsInstance(config["allow_owner_from_final_evidence"], bool)
        self.assertGreaterEqual(
            config["final_evidence_owner_threshold"], config["face_match_threshold"]
        )
        self.assertGreaterEqual(config["enroll_samples"], 8)
        self.assertGreaterEqual(config["enroll_timeout_seconds"], 120)

    def test_launchd_plists_load(self) -> None:
        labels = (
            "com.wuyi.mac-face-lock-agent",
            "com.wuyi.mac-face-lock-status",
        )
        for label in labels:
            with self.subTest(label=label):
                plist_path = PROJECT_DIR / "launchd" / f"{label}.plist"
                with plist_path.open("rb") as handle:
                    data = plistlib.load(handle)
                self.assertEqual(data["Label"], label)
                self.assertIs(data["RunAtLoad"], True)

    def test_ui_launchd_restarts_only_after_unsuccessful_exit(self) -> None:
        with (
            PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-status.plist"
        ).open("rb") as handle:
            data = plistlib.load(handle)

        self.assertIs(data["RunAtLoad"], True)
        self.assertEqual(data["KeepAlive"], {"SuccessfulExit": False})

    def test_agent_launchd_remains_always_alive(self) -> None:
        with (
            PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-agent.plist"
        ).open("rb") as handle:
            data = plistlib.load(handle)

        self.assertIs(data["RunAtLoad"], True)
        self.assertIs(data["KeepAlive"], True)

    def test_ui_launchd_plist_targets_unified_application(self) -> None:
        plist_path = (
            PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-status.plist"
        )
        with plist_path.open("rb") as handle:
            data = plistlib.load(handle)

        executable = data["ProgramArguments"][0]
        self.assertIn(
            "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock",
            executable,
        )


if __name__ == "__main__":
    unittest.main()
