from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

import runtime_cli
from enrollment_state_machine import EnrollmentPose, EnrollmentProgressEvent
from face_verifier import RuntimeDependencyError, VerifyResult


class PassingProbe:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def check_runtime_imports(self):
        self.calls.append("runtime_imports")
        return {"opencv": True, "numpy": True}

    def check_support_directory(self, paths):
        self.calls.append("support_directory")
        return {"support_dir": str(paths.support_dir)}

    def check_camera(self, config):
        self.calls.append("camera")
        return {"camera_index": int(config.get("camera_index", 0))}

    def check_template(self, template_path):
        self.calls.append("template")
        return {"template_path": str(template_path), "sample_count": 2}


class FailingCameraProbe(PassingProbe):
    def check_camera(self, config):
        self.calls.append("camera")
        raise RuntimeError("camera denied")


class MissingRuntimeProbe(PassingProbe):
    def check_runtime_imports(self):
        self.calls.append("runtime_imports")
        raise RuntimeDependencyError("OpenCV import failed")

    def check_camera(self, config):
        self.calls.append("camera")
        raise RuntimeDependencyError("OpenCV import failed")


class RuntimeCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.resources_dir = self.root / "resources"
        self.support_dir = self.root / "support"
        self.resources_dir.mkdir()
        config_path = self.support_dir / "config" / "config.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_text(
            json.dumps({"camera_index": 0, "mode": "observe"}),
            encoding="utf-8",
        )
        template_path = self.support_dir / "data" / "owner_face.npy"
        template_path.parent.mkdir(parents=True)
        np.save(
            template_path,
            np.ones((2, 96 * 96), dtype="float32"),
        )

    def run_cli(self, command: str, *, probe=None):
        output = io.StringIO()
        arguments = [
            "--resources-dir",
            str(self.resources_dir),
            "--support-dir",
            str(self.support_dir),
            command,
        ]
        with redirect_stdout(output):
            returncode = runtime_cli.main(arguments, diagnostic_probe=probe)
        return SimpleNamespace(returncode=returncode, stdout=output.getvalue())

    @staticmethod
    def events(result) -> list[dict[str, object]]:
        return [
            json.loads(line)
            for line in result.stdout.splitlines()
            if line.strip()
        ]

    def test_diagnose_emits_versioned_json(self):
        result = self.run_cli("diagnose", probe=PassingProbe())

        event = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(event["schema_version"], 1)
        self.assertEqual(event["event"], "diagnosis_complete")
        self.assertEqual(event["status"], "success")

    def test_diagnose_reports_checks_independently(self):
        probe = FailingCameraProbe()

        result = self.run_cli("diagnose", probe=probe)

        events = self.events(result)
        self.assertEqual(result.returncode, runtime_cli.EXIT_PERMISSION_OR_CAMERA)
        self.assertEqual(
            probe.calls,
            ["runtime_imports", "support_directory", "camera", "template"],
        )
        checks = {
            event["check"]: event
            for event in events
            if event["event"] == "diagnosis_check"
        }
        self.assertEqual(checks["camera"]["status"], "error")
        self.assertEqual(checks["template"]["status"], "success")
        self.assertEqual(events[-1]["event"], "diagnosis_complete")
        self.assertEqual(events[-1]["status"], "error")

    def test_diagnose_classifies_invalid_config_as_runtime_failure(self):
        (self.support_dir / "config" / "config.json").write_text(
            "{not-json",
            encoding="utf-8",
        )
        probe = PassingProbe()

        result = self.run_cli("diagnose", probe=probe)

        self.assertEqual(result.returncode, runtime_cli.EXIT_RUNTIME_FAILURE)
        self.assertEqual(
            probe.calls,
            ["runtime_imports", "support_directory", "template"],
        )
        events = self.events(result)
        self.assertEqual(events[-1]["event"], "diagnosis_complete")
        self.assertIn("camera", events[-1]["failed_checks"])

    def test_diagnose_classifies_runtime_import_failures_before_camera_failures(self):
        probe = MissingRuntimeProbe()

        result = self.run_cli("diagnose", probe=probe)

        self.assertEqual(result.returncode, runtime_cli.EXIT_RUNTIME_FAILURE)
        self.assertEqual(
            probe.calls,
            ["runtime_imports", "support_directory", "camera", "template"],
        )
        checks = {
            event["check"]: event
            for event in self.events(result)
            if event["event"] == "diagnosis_check"
        }
        self.assertEqual(checks["runtime_imports"]["failure_kind"], "runtime")
        self.assertEqual(checks["camera"]["failure_kind"], "runtime")

    def test_enroll_emits_started_progress_and_complete_events(self):
        output_path = self.support_dir / "data" / "owner_face.npy"

        def fake_enroll(paths, progress):
            progress(1, 2)
            progress(2, 2)
            return output_path

        with patch("runtime_cli.enroll_owner", side_effect=fake_enroll):
            result = self.run_cli("enroll")

        events = self.events(result)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            [event["event"] for event in events],
            [
                "enrollment_started",
                "enrollment_progress",
                "enrollment_progress",
                "enrollment_complete",
            ],
        )
        self.assertEqual(events[1]["captured_samples"], 1)
        self.assertEqual(events[1]["required_samples"], 2)
        self.assertEqual(events[-1]["template_path"], str(output_path))

    def test_enroll_emits_structured_pose_quality_progress(self):
        output_path = self.support_dir / "data" / "owner_face.npy"

        def fake_enroll(paths, progress):
            progress(
                EnrollmentProgressEvent(
                    pose=EnrollmentPose.LEFT.value,
                    quality="rejected",
                    reason="too_dark",
                    accepted_pose_count=1,
                    required_pose_count=5,
                    accepted_sample_count=2,
                    required_sample_count=10,
                )
            )
            return output_path

        with patch("runtime_cli.enroll_owner", side_effect=fake_enroll):
            result = self.run_cli("enroll")

        event = self.events(result)[1]
        self.assertEqual(event["pose"], "left")
        self.assertEqual(event["quality"], "rejected")
        self.assertEqual(event["reason"], "too_dark")
        self.assertEqual(event["accepted_pose_count"], 1)
        self.assertEqual(event["required_pose_count"], 5)

    def test_agent_uses_explicit_release_paths_and_emits_lifecycle_events(self):
        def fake_agent(paths, on_started):
            self.assertEqual(paths.resources_dir, self.resources_dir.resolve())
            self.assertEqual(paths.support_dir, self.support_dir.resolve())
            self.assertFalse(paths.control_fallback_enabled)
            on_started()
            return 0

        with patch("runtime_cli.run_agent", side_effect=fake_agent):
            result = self.run_cli("agent")

        events = self.events(result)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            [event["event"] for event in events],
            ["agent_started", "agent_stopped"],
        )

    def test_verify_owner_success_never_invokes_lock_controller(self):
        result_value = VerifyResult(
            decision="owner",
            owner_hits=2,
            stranger_hits=0,
            no_face_hits=0,
            frames_checked=2,
            reason="owner threshold reached",
        )

        with (
            patch("runtime_cli.load_owner_encoding", return_value=object()),
            patch("runtime_cli.verify_current_user", return_value=result_value),
            patch(
                "lock_controller.lock_screen",
                side_effect=AssertionError("verify-owner must never lock"),
            ) as lock_screen,
        ):
            result = self.run_cli("verify-owner")

        events = self.events(result)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(events[-1]["event"], "owner_verification_complete")
        self.assertEqual(events[-1]["decision"], "owner")
        lock_screen.assert_not_called()

    def test_verify_owner_failure_uses_dedicated_exit_code(self):
        result_value = VerifyResult(
            decision="stranger",
            owner_hits=0,
            stranger_hits=3,
            no_face_hits=0,
            frames_checked=3,
            reason="stranger threshold reached",
        )

        with (
            patch("runtime_cli.load_owner_encoding", return_value=object()),
            patch("runtime_cli.verify_current_user", return_value=result_value),
        ):
            result = self.run_cli("verify-owner")

        self.assertEqual(result.returncode, runtime_cli.EXIT_OWNER_VERIFICATION_FAILED)
        self.assertEqual(self.events(result)[-1]["status"], "error")

    def test_invalid_owner_profile_uses_dedicated_exit_code(self):
        with patch(
            "runtime_cli.load_owner_encoding",
            side_effect=ValueError("bad owner profile"),
        ):
            result = self.run_cli("verify-owner")

        self.assertEqual(result.returncode, runtime_cli.EXIT_OWNER_PROFILE_INVALID)
        self.assertEqual(self.events(result)[-1]["event"], "owner_profile_invalid")

    def test_corrupted_owner_profile_load_errors_use_dedicated_exit_code(self):
        for load_error in (
            OSError("owner profile read failed"),
            EOFError("owner profile is truncated"),
        ):
            with self.subTest(error_type=type(load_error).__name__):
                with patch("face_verifier.np.load", side_effect=load_error):
                    result = self.run_cli("verify-owner")

                self.assertEqual(
                    result.returncode,
                    runtime_cli.EXIT_OWNER_PROFILE_INVALID,
                )
                self.assertEqual(
                    self.events(result)[-1]["event"],
                    "owner_profile_invalid",
                )

    def test_invalid_config_is_a_runtime_failure_not_an_owner_profile_failure(self):
        (self.support_dir / "config" / "config.json").write_text(
            "{not-json",
            encoding="utf-8",
        )

        result = self.run_cli("verify-owner")

        self.assertEqual(result.returncode, runtime_cli.EXIT_RUNTIME_FAILURE)
        self.assertEqual(self.events(result)[-1]["event"], "runtime_failure")

    def test_camera_failure_uses_permission_exit_code(self):
        with (
            patch("runtime_cli.load_owner_encoding", return_value=object()),
            patch(
                "runtime_cli.verify_current_user",
                side_effect=RuntimeError("Could not open camera index 0"),
            ),
        ):
            result = self.run_cli("verify-owner")

        self.assertEqual(result.returncode, runtime_cli.EXIT_PERMISSION_OR_CAMERA)
        self.assertEqual(self.events(result)[-1]["event"], "camera_unavailable")

    def test_open_camera_with_no_readable_frames_uses_camera_exit_code(self):
        capture = SimpleNamespace(
            isOpened=lambda: True,
            read=lambda: (False, None),
            release=lambda: None,
        )
        fake_cv2 = SimpleNamespace(VideoCapture=lambda _index: capture)
        config_path = self.support_dir / "config" / "config.json"
        config_path.write_text(
            json.dumps(
                {
                    "camera_index": 0,
                    "verify_window_seconds": 1,
                    "frame_interval_seconds": 0,
                    "no_face_lock_threshold": 1,
                }
            ),
            encoding="utf-8",
        )

        with (
            patch("runtime_cli.load_owner_encoding", return_value=object()),
            patch("face_verifier._load_runtime_modules", return_value=fake_cv2),
            patch("face_verifier._face_cascades", return_value=[]),
            patch("face_verifier.time.monotonic", side_effect=(0, 0, 2)),
        ):
            result = self.run_cli("verify-owner")

        self.assertEqual(result.returncode, runtime_cli.EXIT_PERMISSION_OR_CAMERA)
        self.assertEqual(self.events(result)[-1]["event"], "camera_unavailable")

    def test_enrollment_timeout_uses_dedicated_repair_event(self):
        with patch(
            "runtime_cli.enroll_owner",
            side_effect=RuntimeError(
                "Enrollment timed out before every configured pose was completed."
            ),
        ):
            result = self.run_cli("enroll")

        self.assertEqual(result.returncode, 13)
        self.assertEqual(self.events(result)[-1]["event"], "enrollment_timeout")

    def test_readable_frames_without_faces_remain_verification_failure(self):
        capture = SimpleNamespace(
            isOpened=lambda: True,
            read=lambda: (True, np.zeros((8, 8, 3), dtype="uint8")),
            release=lambda: None,
        )
        fake_cv2 = SimpleNamespace(VideoCapture=lambda _index: capture)
        config_path = self.support_dir / "config" / "config.json"
        config_path.write_text(
            json.dumps(
                {
                    "camera_index": 0,
                    "verify_window_seconds": 1,
                    "frame_interval_seconds": 0,
                    "no_face_lock_threshold": 1,
                }
            ),
            encoding="utf-8",
        )

        with (
            patch("runtime_cli.load_owner_encoding", return_value=object()),
            patch("face_verifier._load_runtime_modules", return_value=fake_cv2),
            patch("face_verifier._face_cascades", return_value=[]),
            patch("face_verifier._extract_face_template", return_value=None),
            patch("face_verifier.time.monotonic", return_value=0),
        ):
            result = self.run_cli("verify-owner")

        events = self.events(result)
        self.assertEqual(
            result.returncode,
            runtime_cli.EXIT_OWNER_VERIFICATION_FAILED,
        )
        self.assertEqual(events[-1]["event"], "owner_verification_complete")
        self.assertEqual(events[-1]["decision"], "no_face")
        self.assertEqual(events[-1]["frames_checked"], 1)


if __name__ == "__main__":
    unittest.main()
