"""Deterministic, pose-complete enrollment state.

Image detection is kept outside this unit so tests can use synthetic fixtures
without opening a camera.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

import numpy as np


class EnrollmentPose(str, Enum):
    FRONT = "front"
    LEFT = "left"
    RIGHT = "right"
    UP = "up"
    DOWN = "down"


class EnrollmentQualityReason(str, Enum):
    NO_FACE = "no_face"
    MULTIPLE_FACES = "multiple_faces"
    TOO_DARK = "too_dark"
    FACE_TOO_SMALL = "face_too_small"
    FACE_TOO_LARGE = "face_too_large"
    POSE_MISMATCH = "pose_mismatch"


@dataclass(frozen=True)
class FrameAssessment:
    pose: EnrollmentPose | None
    template: np.ndarray | None
    reason: EnrollmentQualityReason | None

    @classmethod
    def accepted(
        cls,
        *,
        pose: EnrollmentPose,
        template: np.ndarray,
    ) -> "FrameAssessment":
        return cls(pose=pose, template=template, reason=None)

    @classmethod
    def rejected(
        cls,
        reason: EnrollmentQualityReason,
    ) -> "FrameAssessment":
        return cls(pose=None, template=None, reason=reason)


@dataclass(frozen=True)
class EnrollmentProgressEvent:
    pose: str
    quality: str
    reason: str | None
    accepted_pose_count: int
    required_pose_count: int
    accepted_sample_count: int
    required_sample_count: int


class EnrollmentStateMachine:
    POSE_SEQUENCE = tuple(EnrollmentPose)

    def __init__(self, *, samples_per_pose: int) -> None:
        if samples_per_pose < 1:
            raise ValueError("samples_per_pose must be positive")
        self.samples_per_pose = samples_per_pose
        self._pose_index = 0
        self._pose_samples = 0
        self._templates: list[np.ndarray] = []

    @property
    def is_complete(self) -> bool:
        return self._pose_index == len(self.POSE_SEQUENCE)

    @property
    def current_pose(self) -> EnrollmentPose:
        if self.is_complete:
            return self.POSE_SEQUENCE[-1]
        return self.POSE_SEQUENCE[self._pose_index]

    @property
    def accepted_pose_count(self) -> int:
        return self._pose_index

    @property
    def accepted_sample_count(self) -> int:
        return len(self._templates)

    @property
    def templates(self) -> tuple[np.ndarray, ...]:
        return tuple(self._templates)

    def consume(self, assessment: FrameAssessment) -> EnrollmentProgressEvent:
        if self.is_complete:
            raise RuntimeError("enrollment is already complete")
        reason = assessment.reason
        if reason is None and assessment.pose != self.current_pose:
            reason = EnrollmentQualityReason.POSE_MISMATCH
        if reason is not None:
            return self._event(quality="rejected", reason=reason.value)
        if assessment.template is None:
            return self._event(
                quality="rejected",
                reason=EnrollmentQualityReason.NO_FACE.value,
            )

        template = np.asarray(assessment.template, dtype="float32")
        if template.shape != (96 * 96,) or not np.isfinite(template).all():
            raise ValueError("invalid enrollment template")
        self._templates.append(template.copy())
        self._pose_samples += 1
        accepted_pose = self.current_pose
        if self._pose_samples == self.samples_per_pose:
            self._pose_index += 1
            self._pose_samples = 0
        return self._event(
            quality="accepted",
            reason=None,
            pose=accepted_pose,
        )

    def _event(
        self,
        *,
        quality: str,
        reason: str | None,
        pose: EnrollmentPose | None = None,
    ) -> EnrollmentProgressEvent:
        return EnrollmentProgressEvent(
            pose=(pose or self.current_pose).value,
            quality=quality,
            reason=reason,
            accepted_pose_count=self.accepted_pose_count,
            required_pose_count=len(self.POSE_SEQUENCE),
            accepted_sample_count=self.accepted_sample_count,
            required_sample_count=len(self.POSE_SEQUENCE) * self.samples_per_pose,
        )
