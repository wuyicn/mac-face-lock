from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from enrollment_state_machine import EnrollmentPose, FrameAssessment
from face_verifier import capture_owner_profile


class FaceEnrollmentIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.output = Path(self.temporary_directory.name) / "owner_face.npy"
        self.frame = np.zeros((120, 160, 3), dtype="uint8")

    def fake_cv2(self, frames: list[np.ndarray]):
        queue = list(frames)
        capture = SimpleNamespace(
            isOpened=lambda: True,
            read=lambda: (True, queue.pop(0)) if queue else (False, None),
            release=lambda: None,
        )
        return SimpleNamespace(VideoCapture=lambda _index: capture)

    def test_capture_replaces_template_only_after_all_five_poses(self) -> None:
        poses = [pose for pose in EnrollmentPose for _ in range(2)]
        events = []

        def assess(_frame, expected_pose):
            pose = poses.pop(0)
            self.assertEqual(pose, expected_pose)
            return FrameAssessment.accepted(
                pose=pose,
                template=np.ones(96 * 96, dtype="float32"),
            )

        with (
            patch(
                "face_verifier._load_runtime_modules",
                return_value=self.fake_cv2([self.frame] * 10),
            ),
            patch("face_verifier._face_cascades", return_value=[]),
            patch("face_verifier.time.monotonic", return_value=0),
            patch("face_verifier.time.sleep"),
        ):
            capture_owner_profile(
                {"enroll_samples_per_pose": 2, "enroll_timeout_seconds": 60},
                self.output,
                progress=events.append,
                assess_frame=assess,
            )

        saved = np.load(self.output, allow_pickle=False)
        self.assertEqual(saved.shape, (10, 96 * 96))
        self.assertEqual(events[-1].accepted_pose_count, 5)

    def test_timeout_preserves_existing_template(self) -> None:
        existing = np.full((2, 96 * 96), 7, dtype="float32")
        np.save(self.output, existing)
        assessment = FrameAssessment.accepted(
            pose=EnrollmentPose.FRONT,
            template=np.ones(96 * 96, dtype="float32"),
        )

        with (
            patch(
                "face_verifier._load_runtime_modules",
                return_value=self.fake_cv2([self.frame]),
            ),
            patch("face_verifier._face_cascades", return_value=[]),
            patch("face_verifier.time.monotonic", side_effect=[0, 0, 2]),
            patch("face_verifier.time.sleep"),
        ):
            with self.assertRaisesRegex(RuntimeError, "every configured pose"):
                capture_owner_profile(
                    {
                        "enroll_samples_per_pose": 2,
                        "enroll_timeout_seconds": 1,
                    },
                    self.output,
                    assess_frame=lambda _frame, _pose: assessment,
                )

        np.testing.assert_array_equal(
            np.load(self.output, allow_pickle=False),
            existing,
        )


if __name__ == "__main__":
    unittest.main()
