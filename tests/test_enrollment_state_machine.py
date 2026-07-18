from __future__ import annotations

import unittest

import numpy as np

from enrollment_state_machine import (
    EnrollmentPose,
    EnrollmentQualityReason,
    EnrollmentStateMachine,
    FrameAssessment,
)


class EnrollmentStateMachineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.machine = EnrollmentStateMachine(samples_per_pose=2)
        self.sample = np.ones(96 * 96, dtype="float32")

    def accept(self, pose: EnrollmentPose) -> None:
        for _ in range(2):
            event = self.machine.consume(
                FrameAssessment.accepted(pose=pose, template=self.sample)
            )
            self.assertEqual(event.quality, "accepted")

    def test_requires_every_pose_before_completion(self) -> None:
        for pose in list(EnrollmentPose)[:-1]:
            self.accept(pose)
        self.assertFalse(self.machine.is_complete)
        self.assertEqual(self.machine.current_pose, EnrollmentPose.DOWN)
        self.accept(EnrollmentPose.DOWN)
        self.assertTrue(self.machine.is_complete)
        self.assertEqual(self.machine.accepted_pose_count, 5)
        self.assertEqual(len(self.machine.templates), 10)

    def test_rejection_preserves_current_pose_and_progress(self) -> None:
        event = self.machine.consume(
            FrameAssessment.rejected(EnrollmentQualityReason.TOO_DARK)
        )
        self.assertEqual(event.reason, "too_dark")
        self.assertEqual(event.pose, "front")
        self.assertEqual(event.accepted_pose_count, 0)
        self.assertEqual(event.accepted_sample_count, 0)
        self.assertEqual(self.machine.current_pose, EnrollmentPose.FRONT)

    def test_rejects_pose_mismatch_zero_multiple_and_bad_size(self) -> None:
        reasons = (
            EnrollmentQualityReason.NO_FACE,
            EnrollmentQualityReason.MULTIPLE_FACES,
            EnrollmentQualityReason.FACE_TOO_SMALL,
            EnrollmentQualityReason.FACE_TOO_LARGE,
            EnrollmentQualityReason.POSE_MISMATCH,
        )
        for reason in reasons:
            with self.subTest(reason=reason):
                event = self.machine.consume(FrameAssessment.rejected(reason))
                self.assertEqual(event.reason, reason.value)
                self.assertEqual(self.machine.accepted_sample_count, 0)


if __name__ == "__main__":
    unittest.main()
