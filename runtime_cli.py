#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

from enrollment_state_machine import EnrollmentProgressEvent
from agent import main as run_agent
from camera_diagnostic import run_diagnostics
from enroll_owner import enroll_owner
from face_verifier import (
    CameraUnavailableError,
    RuntimeDependencyError,
    load_owner_encoding,
    verify_current_user,
)
from runtime_paths import RuntimePaths


EXIT_SUCCESS = 0
EXIT_INVALID_ARGUMENTS = 2
EXIT_PERMISSION_OR_CAMERA = 10
EXIT_OWNER_PROFILE_INVALID = 11
EXIT_OWNER_VERIFICATION_FAILED = 12
EXIT_ENROLLMENT_TIMEOUT = 13
EXIT_RUNTIME_FAILURE = 20
ENROLLMENT_TIMEOUT_MESSAGE = (
    "Enrollment timed out before every configured pose was completed."
)


def emit(event: str, status: str, message: str, **fields: object) -> None:
    payload = {
        "schema_version": 1,
        "event": event,
        "status": status,
        "message": message,
        **fields,
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--resources-dir", required=True, type=Path)
    parser.add_argument("--support-dir", required=True, type=Path)
    parser.add_argument(
        "command",
        choices=("agent", "enroll", "diagnose", "verify-owner"),
    )
    return parser


def _load_config(paths: RuntimePaths) -> dict[str, Any]:
    return json.loads(paths.config_path.read_text(encoding="utf-8"))


def _run_agent_command(paths: RuntimePaths) -> int:
    result = run_agent(
        paths,
        lambda: emit(
            "agent_started",
            "success",
            "Face lock agent started",
            support_dir=str(paths.support_dir),
        ),
    )
    emit("agent_stopped", "success", "Face lock agent stopped")
    return int(result)


def _run_enroll_command(paths: RuntimePaths) -> int:
    emit(
        "enrollment_started",
        "success",
        "Owner enrollment started",
        template_path=str(paths.owner_face_path),
    )

    def progress(
        event_or_captured: EnrollmentProgressEvent | int,
        required_samples: int | None = None,
    ) -> None:
        if isinstance(event_or_captured, EnrollmentProgressEvent):
            fields = {
                "pose": event_or_captured.pose,
                "quality": event_or_captured.quality,
                "reason": event_or_captured.reason,
                "accepted_pose_count": event_or_captured.accepted_pose_count,
                "required_pose_count": event_or_captured.required_pose_count,
                "captured_samples": event_or_captured.accepted_sample_count,
                "required_samples": event_or_captured.required_sample_count,
            }
        else:
            fields = {
                "captured_samples": event_or_captured,
                "required_samples": required_samples,
            }
        emit(
            "enrollment_progress",
            "success" if fields.get("quality") != "rejected" else "retry",
            "Owner enrollment progress",
            **fields,
        )

    output_path = enroll_owner(paths, progress)
    emit(
        "enrollment_complete",
        "success",
        "Owner enrollment completed",
        template_path=str(output_path),
    )
    return EXIT_SUCCESS


def _run_diagnose_command(paths: RuntimePaths, probe: Any | None) -> int:
    results = run_diagnostics(paths, probe)
    for result in results:
        emit(
            "diagnosis_check",
            result.status,
            result.message,
            check=result.check,
            **result.fields,
        )

    failures = {result.check for result in results if result.status != "success"}
    runtime_failure = any(
        result.fields.get("failure_kind") == "runtime"
        for result in results
        if result.status != "success"
    )
    if not failures:
        exit_code = EXIT_SUCCESS
    elif runtime_failure:
        exit_code = EXIT_RUNTIME_FAILURE
    elif "camera" in failures:
        exit_code = EXIT_PERMISSION_OR_CAMERA
    elif "template" in failures:
        exit_code = EXIT_OWNER_PROFILE_INVALID
    else:
        exit_code = EXIT_RUNTIME_FAILURE
    status = "success" if exit_code == EXIT_SUCCESS else "error"
    emit(
        "diagnosis_complete",
        status,
        (
            "Runtime diagnosis completed"
            if status == "success"
            else "Runtime diagnosis found one or more failures"
        ),
        failed_checks=sorted(failures),
    )
    return exit_code


def _is_camera_error(exc: Exception) -> bool:
    if isinstance(exc, CameraUnavailableError):
        return True
    message = str(exc).lower()
    return "camera" in message or "摄像头" in message


def _is_enrollment_timeout(error: RuntimeError) -> bool:
    return str(error) == ENROLLMENT_TIMEOUT_MESSAGE


def _run_verify_owner_command(paths: RuntimePaths) -> int:
    config = _load_config(paths)
    try:
        owner_encoding = load_owner_encoding(paths.owner_face_path)
    except (FileNotFoundError, ValueError) as exc:
        emit(
            "owner_profile_invalid",
            "error",
            str(exc),
            template_path=str(paths.owner_face_path),
        )
        return EXIT_OWNER_PROFILE_INVALID

    result = verify_current_user(config, owner_encoding)
    success = result.decision == "owner"
    emit(
        "owner_verification_complete",
        "success" if success else "error",
        "Owner verified" if success else "Owner verification failed",
        decision=result.decision,
        owner_hits=result.owner_hits,
        stranger_hits=result.stranger_hits,
        no_face_hits=result.no_face_hits,
        frames_checked=result.frames_checked,
        reason=result.reason,
    )
    return EXIT_SUCCESS if success else EXIT_OWNER_VERIFICATION_FAILED


def main(
    argv: Sequence[str] | None = None,
    *,
    diagnostic_probe: Any | None = None,
) -> int:
    arguments = _parser().parse_args(argv)
    paths = RuntimePaths.for_release(
        arguments.resources_dir,
        arguments.support_dir,
    )
    try:
        if arguments.command == "agent":
            return _run_agent_command(paths)
        if arguments.command == "enroll":
            return _run_enroll_command(paths)
        if arguments.command == "diagnose":
            return _run_diagnose_command(paths, diagnostic_probe)
        return _run_verify_owner_command(paths)
    except CameraUnavailableError as exc:
        emit("camera_unavailable", "error", str(exc))
        return EXIT_PERMISSION_OR_CAMERA
    except RuntimeDependencyError as exc:
        emit("runtime_failure", "error", str(exc))
        return EXIT_RUNTIME_FAILURE
    except RuntimeError as exc:
        if _is_camera_error(exc):
            emit("camera_unavailable", "error", str(exc))
            return EXIT_PERMISSION_OR_CAMERA
        if _is_enrollment_timeout(exc):
            emit("enrollment_timeout", "error", str(exc))
            return EXIT_ENROLLMENT_TIMEOUT
        emit("runtime_failure", "error", str(exc))
        return EXIT_RUNTIME_FAILURE
    except Exception as exc:
        emit("runtime_failure", "error", str(exc))
        return EXIT_RUNTIME_FAILURE


if __name__ == "__main__":
    raise SystemExit(main())
