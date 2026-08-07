#!/usr/bin/env python3
"""Camera capture and local owner face verification.

This MVP intentionally uses OpenCV only. It stores a local face template made
from normalized face crops so the project can run before a heavier embedding
model is introduced.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from camera_backend import open_camera
from enrollment_state_machine import (
    EnrollmentPose,
    EnrollmentProgressEvent,
    EnrollmentQualityReason,
    EnrollmentStateMachine,
    FrameAssessment,
)
from runtime_paths import RuntimePaths
from template_store import replace_owner_template


PROJECT_DIR = Path(__file__).resolve().parent
OWNER_FACE_PATH = RuntimePaths.for_source(PROJECT_DIR).owner_face_path
FACE_SIZE = (96, 96)


@dataclass
class VerifyResult:
    decision: str
    owner_hits: int
    stranger_hits: int
    no_face_hits: int
    frames_checked: int
    reason: str


class RuntimeDependencyError(RuntimeError):
    pass


class CameraUnavailableError(RuntimeError):
    pass


class OwnerProfileInvalidError(ValueError):
    pass


def _load_runtime_modules() -> Any:
    try:
        import cv2  # type: ignore
    except ImportError as exc:
        raise RuntimeDependencyError(
            "Missing OpenCV dependency. Run scripts/bootstrap.sh first."
        ) from exc
    return cv2


def load_owner_encoding(path: Path = OWNER_FACE_PATH) -> np.ndarray:
    try:
        if not path.exists():
            raise FileNotFoundError(
                f"Owner profile not found: {path}. Run python3 enroll_owner.py first."
            )
        encoding = np.load(path, allow_pickle=False)
        vector_size = FACE_SIZE[0] * FACE_SIZE[1]
        if encoding.shape == (vector_size,):
            return _normalize_templates(encoding.reshape(1, -1))
        if encoding.ndim == 2 and encoding.shape[1] == vector_size:
            return _normalize_templates(encoding)
        if encoding.shape == FACE_SIZE:
            return _normalize_templates(encoding.reshape(1, -1))
        if encoding.ndim == 3 and encoding.shape[1:] == FACE_SIZE:
            return _normalize_templates(encoding.reshape(encoding.shape[0], -1))
        raise ValueError(f"Invalid owner profile shape: {encoding.shape}")
    except (OSError, EOFError, ValueError) as exc:
        raise OwnerProfileInvalidError(
            f"Invalid owner profile at {path}: {exc}"
        ) from exc


def _normalize_templates(templates: np.ndarray) -> np.ndarray:
    matrix = templates.astype("float32")
    if matrix.ndim == 1:
        matrix = matrix.reshape(1, -1)
    if not np.isfinite(matrix).all():
        raise ValueError("Owner profile contains non-finite values")
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    if np.any(norms == 0):
        raise ValueError("Owner profile contains an empty face template")
    return matrix / norms


def _face_cascades(cv2: Any, config: dict[str, Any] | None = None) -> list[tuple[str, Any, bool]]:
    cascade_path = Path(cv2.data.haarcascades) / "haarcascade_frontalface_default.xml"
    cascade = cv2.CascadeClassifier(str(cascade_path))
    if cascade.empty():
        raise RuntimeError(f"Could not load face cascade: {cascade_path}")
    cascades: list[tuple[str, Any, bool]] = [("frontal", cascade, False)]

    use_profile = True
    if config is not None:
        use_profile = bool(config.get("use_profile_face_detector", True))
    if use_profile:
        profile_path = Path(cv2.data.haarcascades) / "haarcascade_profileface.xml"
        profile = cv2.CascadeClassifier(str(profile_path))
        if not profile.empty():
            cascades.append(("profile", profile, False))
            cascades.append(("profile_mirror", profile, True))
    return cascades


def _box_area(box: tuple[int, int, int, int]) -> int:
    return int(box[2] * box[3])


def _box_iou(left: tuple[int, int, int, int], right: tuple[int, int, int, int]) -> float:
    lx, ly, lw, lh = left
    rx, ry, rw, rh = right
    x1 = max(lx, rx)
    y1 = max(ly, ry)
    x2 = min(lx + lw, rx + rw)
    y2 = min(ly + lh, ry + rh)
    if x2 <= x1 or y2 <= y1:
        return 0.0
    intersection = (x2 - x1) * (y2 - y1)
    union = _box_area(left) + _box_area(right) - intersection
    if union <= 0:
        return 0.0
    return float(intersection / union)


def _merge_face_boxes(boxes: list[tuple[int, int, int, int]]) -> list[tuple[int, int, int, int]]:
    merged: list[tuple[int, int, int, int]] = []
    for box in sorted(boxes, key=_box_area, reverse=True):
        if any(_box_iou(box, existing) >= 0.35 for existing in merged):
            continue
        merged.append(box)
    return merged


def _detect_face_boxes(cv2: Any, cascades: list[tuple[str, Any, bool]], gray: np.ndarray) -> list[tuple[int, int, int, int]]:
    width = gray.shape[1]
    boxes: list[tuple[int, int, int, int]] = []
    for _, cascade, use_mirror in cascades:
        source = cv2.flip(gray, 1) if use_mirror else gray
        detected = cascade.detectMultiScale(
            source,
            scaleFactor=1.08,
            minNeighbors=4,
            minSize=(70, 70),
        )
        for x, y, w, h in detected:
            if use_mirror:
                x = width - x - w
            boxes.append((int(x), int(y), int(w), int(h)))
    return _merge_face_boxes(boxes)


def _extract_face_template(cv2: Any, cascades: list[tuple[str, Any, bool]], frame: np.ndarray) -> np.ndarray | None:
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    faces = _detect_face_boxes(cv2, cascades, gray)
    if not faces:
        return None
    faces = sorted(faces, key=_box_area, reverse=True)
    if len(faces) > 1 and _box_area(faces[1]) >= _box_area(faces[0]) * 0.65:
        return None
    x, y, w, h = faces[0]
    face = gray[y : y + h, x : x + w]
    face = cv2.resize(face, FACE_SIZE)
    face = cv2.equalizeHist(face)
    vector = face.astype("float32").reshape(-1)
    norm = np.linalg.norm(vector)
    if norm == 0:
        return None
    return vector / norm


def _best_similarity(owner_templates: np.ndarray, template: np.ndarray) -> float:
    templates = _normalize_templates(owner_templates)
    normalized_template = template / np.linalg.norm(template)
    scores = templates @ normalized_template
    return float(np.max(scores))


def evidence_matches_owner(
    config: dict[str, Any],
    owner_encoding: np.ndarray,
    evidence_path: Path,
) -> tuple[bool, float | None]:
    cv2 = _load_runtime_modules()
    frame = cv2.imread(str(evidence_path))
    if frame is None:
        return False, None
    template = _extract_face_template(cv2, _face_cascades(cv2, config), frame)
    if template is None:
        return False, None
    score = _best_similarity(owner_encoding, template)
    threshold = max(
        float(config.get("face_match_threshold", 0.72)),
        float(config.get("final_evidence_owner_threshold", 0.82)),
    )
    return score >= threshold, score


def capture_owner_profile(
    config: dict[str, Any],
    output_path: Path = OWNER_FACE_PATH,
    progress: Callable[[EnrollmentProgressEvent], None] | None = None,
    assess_frame: Callable[[np.ndarray, EnrollmentPose], FrameAssessment] | None = None,
) -> Path:
    cv2 = _load_runtime_modules()
    camera_index = int(config.get("camera_index", 0))
    cascades = _face_cascades(cv2, config)
    samples_per_pose = int(config.get("enroll_samples_per_pose", 2))
    timeout_seconds = float(config.get("enroll_timeout_seconds", 60))
    machine = EnrollmentStateMachine(samples_per_pose=samples_per_pose)
    classifier = assess_frame or (
        lambda frame, expected_pose: _assess_enrollment_frame(
            cv2,
            cascades,
            frame,
            expected_pose,
            config,
        )
    )

    cap = open_camera(cv2, camera_index)
    if not cap.isOpened():
        raise CameraUnavailableError(f"Could not open camera index {camera_index}")

    deadline = time.monotonic() + timeout_seconds
    try:
        while time.monotonic() < deadline and not machine.is_complete:
            ok, frame = cap.read()
            if not ok or frame is None:
                time.sleep(0.2)
                continue
            event = machine.consume(classifier(frame, machine.current_pose))
            if progress is not None:
                progress(event)
            time.sleep(0.2 if event.quality == "rejected" else 0.35)
    finally:
        cap.release()

    if not machine.is_complete:
        raise RuntimeError(
            "Enrollment timed out before every configured pose was completed."
        )

    owner_templates = _normalize_templates(np.stack(machine.templates))
    replace_owner_template(owner_templates, output_path)
    return output_path


def _assess_enrollment_frame(
    cv2: Any,
    cascades: list[tuple[str, Any, bool]],
    frame: np.ndarray,
    expected_pose: EnrollmentPose,
    config: dict[str, Any],
) -> FrameAssessment:
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    if float(np.mean(gray)) < float(config.get("enroll_min_brightness", 45.0)):
        return FrameAssessment.rejected(EnrollmentQualityReason.TOO_DARK)

    observations: list[tuple[str, tuple[int, int, int, int]]] = []
    width = gray.shape[1]
    for label, cascade, use_mirror in cascades:
        source = cv2.flip(gray, 1) if use_mirror else gray
        for x, y, w, h in cascade.detectMultiScale(
            source,
            scaleFactor=1.08,
            minNeighbors=4,
            minSize=(70, 70),
        ):
            if use_mirror:
                x = width - x - w
            observations.append((label, (int(x), int(y), int(w), int(h))))

    boxes = _merge_face_boxes([box for _, box in observations])
    if not boxes:
        return FrameAssessment.rejected(EnrollmentQualityReason.NO_FACE)
    if len(boxes) != 1:
        return FrameAssessment.rejected(EnrollmentQualityReason.MULTIPLE_FACES)

    box = boxes[0]
    frame_area = int(gray.shape[0] * gray.shape[1])
    ratio = _box_area(box) / max(frame_area, 1)
    if ratio < float(config.get("enroll_min_face_ratio", 0.08)):
        return FrameAssessment.rejected(EnrollmentQualityReason.FACE_TOO_SMALL)
    if ratio > float(config.get("enroll_max_face_ratio", 0.55)):
        return FrameAssessment.rejected(EnrollmentQualityReason.FACE_TOO_LARGE)

    matching_labels = [
        label
        for label, observed in observations
        if _box_iou(box, observed) >= 0.35
    ]
    pose = _classify_enrollment_pose(
        cv2,
        gray,
        box,
        matching_labels,
        config,
    )
    if pose != expected_pose:
        return FrameAssessment(
            pose=pose,
            template=None,
            reason=EnrollmentQualityReason.POSE_MISMATCH,
        )

    x, y, w, h = box
    face = cv2.resize(gray[y : y + h, x : x + w], FACE_SIZE)
    face = cv2.equalizeHist(face)
    vector = face.astype("float32").reshape(-1)
    norm = np.linalg.norm(vector)
    if norm == 0:
        return FrameAssessment.rejected(EnrollmentQualityReason.NO_FACE)
    return FrameAssessment.accepted(pose=pose, template=vector / norm)


def _classify_enrollment_pose(
    cv2: Any,
    gray: np.ndarray,
    box: tuple[int, int, int, int],
    labels: list[str],
    config: dict[str, Any],
) -> EnrollmentPose:
    if "profile" in labels and "frontal" not in labels:
        return EnrollmentPose.LEFT
    if "profile_mirror" in labels and "frontal" not in labels:
        return EnrollmentPose.RIGHT

    x, y, w, h = box
    face = gray[y : y + h, x : x + w]
    eye_path = Path(cv2.data.haarcascades) / "haarcascade_eye.xml"
    eye_cascade = cv2.CascadeClassifier(str(eye_path))
    if not eye_cascade.empty():
        eyes = eye_cascade.detectMultiScale(
            face,
            scaleFactor=1.08,
            minNeighbors=4,
            minSize=(12, 12),
        )
        if len(eyes) >= 2:
            eye_ratio = float(
                np.mean([eye_y + eye_h / 2 for _, eye_y, _, eye_h in eyes[:2]])
                / max(h, 1)
            )
            if eye_ratio >= float(config.get("enroll_up_eye_ratio", 0.43)):
                return EnrollmentPose.UP
            if eye_ratio <= float(config.get("enroll_down_eye_ratio", 0.30)):
                return EnrollmentPose.DOWN
    return EnrollmentPose.FRONT


def verify_current_user(config: dict[str, Any], owner_encoding: np.ndarray) -> VerifyResult:
    cv2 = _load_runtime_modules()
    camera_index = int(config.get("camera_index", 0))
    cascades = _face_cascades(cv2, config)
    threshold = float(config.get("face_match_threshold", 0.72))
    verify_window = float(config.get("verify_window_seconds", 3.0))
    frame_interval = float(config.get("frame_interval_seconds", 0.4))
    owner_threshold = int(config.get("owner_pass_threshold", 2))
    stranger_threshold = int(config.get("stranger_lock_threshold", 3))
    no_face_threshold = int(config.get("no_face_lock_threshold", 5))

    cap = open_camera(cv2, camera_index)
    if not cap.isOpened():
        raise CameraUnavailableError(f"Could not open camera index {camera_index}")

    owner_hits = 0
    stranger_hits = 0
    no_face_hits = 0
    frames_checked = 0
    deadline = time.monotonic() + verify_window

    try:
        while time.monotonic() < deadline:
            ok, frame = cap.read()
            if not ok or frame is None:
                time.sleep(frame_interval)
                continue

            frames_checked += 1
            template = _extract_face_template(cv2, cascades, frame)
            if template is None:
                no_face_hits += 1
            else:
                score = _best_similarity(owner_encoding, template)
                if score >= threshold:
                    owner_hits += 1
                else:
                    stranger_hits += 1

            if owner_hits >= owner_threshold:
                return VerifyResult(
                    decision="owner",
                    owner_hits=owner_hits,
                    stranger_hits=stranger_hits,
                    no_face_hits=no_face_hits,
                    frames_checked=frames_checked,
                    reason="owner threshold reached",
                )
            if stranger_hits >= stranger_threshold:
                return VerifyResult(
                    decision="stranger",
                    owner_hits=owner_hits,
                    stranger_hits=stranger_hits,
                    no_face_hits=no_face_hits,
                    frames_checked=frames_checked,
                    reason="stranger threshold reached",
                )
            if no_face_hits >= no_face_threshold:
                return VerifyResult(
                    decision="no_face",
                    owner_hits=owner_hits,
                    stranger_hits=stranger_hits,
                    no_face_hits=no_face_hits,
                    frames_checked=frames_checked,
                    reason="no-face threshold reached",
                )

            time.sleep(frame_interval)
    finally:
        cap.release()

    if frames_checked == 0:
        raise CameraUnavailableError(
            f"Could not read camera index {camera_index}"
        )

    return VerifyResult(
        decision="unknown",
        owner_hits=owner_hits,
        stranger_hits=stranger_hits,
        no_face_hits=no_face_hits,
        frames_checked=frames_checked,
        reason="verification window expired",
    )
