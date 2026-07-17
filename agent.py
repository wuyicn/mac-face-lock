#!/usr/bin/env python3
"""Input-triggered face verification agent for macOS."""

from __future__ import annotations

import json
import logging
import math
import signal
import threading
import time
from collections.abc import Callable
from pathlib import Path
from queue import Empty, Full, Queue
from typing import Any

from activity_store import ACTIVITY_PATH, append_activity
from control_store import CONTROL_PATH, ControlState, read_control
from evidence_store import capture_camera_evidence, capture_screen_evidence
from face_verifier import VerifyResult, evidence_matches_owner, load_owner_encoding, verify_current_user
from lock_controller import lock_screen
from runtime_paths import RuntimePaths
from state_store import now_iso, replace_state, write_state
from event_notifier import notify_lock_event


PROJECT_DIR = Path(__file__).resolve().parent
RUNTIME_PATHS = RuntimePaths.for_source(PROJECT_DIR)
CONFIG_PATH = RUNTIME_PATHS.config_path
LOG_PATH = RUNTIME_PATHS.logs_dir / "agent.log"
PID_PATH = RUNTIME_PATHS.logs_dir / "agent.pid"


def normalize_runtime_config(config: dict[str, Any]) -> dict[str, Any]:
    effective = dict(config)
    effective["lock_on_camera_error"] = False
    for key in (
        "cooldown_seconds_after_lock",
        "camera_error_cooldown_seconds",
    ):
        try:
            value = float(effective.get(key, 300))
        except (TypeError, ValueError, OverflowError):
            value = 300.0
        if not math.isfinite(value):
            value = 300.0
        effective[key] = max(300.0, value)
    return effective


class ActivityWriter:
    """Bounded, best-effort activity persistence owned by one daemon thread."""

    def __init__(
        self,
        path: Path,
        *,
        maxsize: int = 128,
        append_fn: Callable[..., Any] | None = None,
        thread_factory: Callable[..., threading.Thread] = threading.Thread,
    ) -> None:
        self.path = path
        self.append_fn = append_fn if append_fn is not None else append_activity
        self.queue: Queue[dict[str, Any]] = Queue(maxsize=max(1, maxsize))
        self.stop_event = threading.Event()
        self.lifecycle_lock = threading.Lock()
        self.closing = False
        self.thread = thread_factory(
            target=self._run,
            name="face-lock-activity-writer",
            daemon=True,
        )
        self.thread.start()

    def enqueue(self, event: dict[str, Any]) -> bool:
        with self.lifecycle_lock:
            if self.closing:
                logging.warning(
                    "activity writer closing; dropping telemetry type=%s",
                    event["event_type"],
                )
                return False
            try:
                self.queue.put_nowait(event)
                return True
            except Full:
                logging.warning(
                    "activity queue full; dropping telemetry type=%s",
                    event["event_type"],
                )
                return False

    def stop(self, timeout: float | None = None) -> bool:
        with self.lifecycle_lock:
            self.closing = True
            self.stop_event.set()
        if threading.current_thread() is not self.thread:
            self.thread.join(timeout)
        return not self.thread.is_alive()

    def _run(self) -> None:
        while not self.stop_event.is_set() or not self.queue.empty():
            try:
                event = self.queue.get(timeout=0.1)
            except Empty:
                continue
            try:
                metadata = event["metadata"]
                if metadata is None:
                    self.append_fn(
                        event["event_type"],
                        event["title"],
                        event["detail"],
                        event["severity"],
                        path=self.path,
                    )
                else:
                    self.append_fn(
                        event["event_type"],
                        event["title"],
                        event["detail"],
                        event["severity"],
                        metadata,
                        path=self.path,
                    )
            except Exception:
                logging.exception(
                    "activity append failed; dropping telemetry type=%s",
                    event["event_type"],
                )
            finally:
                self.queue.task_done()


class FaceLockAgent:
    def __init__(
        self,
        config: dict[str, Any],
        *,
        runtime_paths: RuntimePaths | None = None,
        control_path: Path | None = None,
        activity_path: Path | None = None,
        activity_writer: Any | None = None,
        activity_thread_factory: Callable[..., threading.Thread] = threading.Thread,
    ) -> None:
        self.runtime_paths = runtime_paths or RUNTIME_PATHS
        self.explicit_runtime_paths = runtime_paths is not None
        control_path = control_path or self.runtime_paths.control_path
        activity_path = activity_path or self.runtime_paths.activity_path
        self.config = normalize_runtime_config(config)
        self.mode = str(self.config.get("mode", "observe"))
        self.control_path = control_path
        self.activity_path = activity_path
        self.control_gate = threading.RLock()
        self.control_generation = 0
        self.activity_writer = (
            activity_writer
            if activity_writer is not None
            else ActivityWriter(
                activity_path,
                maxsize=int(self.config.get("activity_queue_maxsize", 128)),
                thread_factory=activity_thread_factory,
            )
        )
        control_fallback = ControlState(
            self.runtime_paths.control_fallback_enabled,
            None,
        )
        self.protection_enabled = read_control(
            control_path,
            control_fallback,
        ).protection_enabled
        if self.explicit_runtime_paths:
            self.owner_encoding = load_owner_encoding(self.runtime_paths.owner_face_path)
        else:
            self.owner_encoding = load_owner_encoding()
        self.stop_event = threading.Event()
        self.verify_lock = threading.Lock()
        self.verify_workers_lock = threading.Lock()
        self.verify_workers: set[threading.Thread] = set()
        self.last_pass_at = -float("inf")
        self.last_lock_at = -float("inf")
        self.last_camera_error_at = -float("inf")
        self.last_activity_at = time.monotonic()
        self.last_active_state_at = 0.0
        self.last_armed_state_at = 0.0
        self.armed = False
        self.mouse_listener: Any | None = None
        self.keyboard_listener: Any | None = None
        self.system_idle_supported: bool | None = None

    def persist_state(self, state: dict[str, Any]) -> None:
        if self.explicit_runtime_paths:
            write_state(state, path=self.runtime_paths.state_path)
        else:
            write_state(state)

    def persist_replacement_state(self, state: dict[str, Any]) -> None:
        if self.explicit_runtime_paths:
            replace_state(state, path=self.runtime_paths.state_path)
        else:
            replace_state(state)

    def refresh_control_state(self) -> None:
        current = ControlState(self.protection_enabled, None)
        desired = read_control(self.control_path, current)
        with self.control_gate:
            if desired.protection_enabled == self.protection_enabled:
                return
            self.protection_enabled = desired.protection_enabled
            self.control_generation += 1
            self.armed = False
            self.last_activity_at = time.monotonic()
            self.last_active_state_at = self.last_activity_at
            if self.protection_enabled:
                self.persist_state(
                    {
                        "status": "active",
                        "mode": self.mode,
                        "armed": False,
                        "action": "wait_until_idle",
                        "heartbeat": "active",
                    }
                )
                self.queue_activity(
                    "protection_resumed",
                    "已恢复保护",
                    "从正常使用状态重新开始计时",
                    "info",
                )
            else:
                self.persist_state(
                    {
                        "status": "paused",
                        "mode": self.mode,
                        "armed": False,
                        "action": "allow_paused",
                        "heartbeat": "paused",
                    }
                )
                self.queue_activity(
                    "protection_paused",
                    "已暂停保护",
                    "不会布防、验证或锁屏",
                    "warning",
                )

    def write_active_state(self, state: dict[str, Any]) -> bool:
        with self.control_gate:
            generation = self.control_generation
            if not self.protection_enabled or generation != self.control_generation:
                return False
            self.persist_state(state)
            return bool(self.protection_enabled) and generation == self.control_generation

    def run_active_action(self, action: Callable[[], Any]) -> tuple[bool, Any]:
        with self.control_gate:
            generation = self.control_generation
            if not self.protection_enabled or generation != self.control_generation:
                return False, None
            result = action()
            active = bool(self.protection_enabled) and generation == self.control_generation
            return active, result

    def protection_is_active(self) -> bool:
        with self.control_gate:
            return bool(self.protection_enabled)

    def queue_activity(
        self,
        event_type: str,
        title: str,
        detail: str,
        severity: str,
        metadata: dict[str, Any] | None = None,
    ) -> bool:
        return self.enqueue_activity_event(
            self.build_activity_event(
                event_type,
                title,
                detail,
                severity,
                metadata,
            )
        )

    def build_activity_event(
        self,
        event_type: str,
        title: str,
        detail: str,
        severity: str,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return {
            "event_type": event_type,
            "title": title,
            "detail": detail,
            "severity": severity,
            "metadata": metadata,
        }

    def enqueue_activity_event(self, event: dict[str, Any]) -> bool:
        return bool(self.activity_writer.enqueue(event))

    def record_activity(
        self,
        event_type: str,
        title: str,
        detail: str,
        severity: str,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.queue_activity(event_type, title, detail, severity, metadata)

    def stop_activity_writer(self, timeout: float | None = None) -> bool:
        return bool(self.activity_writer.stop(timeout))

    def start_verification_worker(self, source: str) -> None:
        worker = threading.Thread(
            target=self.run_verification_worker,
            args=(source,),
            name=f"face-lock-verify-{source}",
            daemon=False,
        )
        with self.verify_workers_lock:
            self.verify_workers.add(worker)
        try:
            worker.start()
        except Exception:
            with self.verify_workers_lock:
                self.verify_workers.discard(worker)
            if self.verify_lock.locked():
                self.verify_lock.release()
            raise

    def run_verification_worker(self, source: str) -> None:
        try:
            self.verify_and_act(source)
        finally:
            current = threading.current_thread()
            with self.verify_workers_lock:
                self.verify_workers.discard(current)
                last_worker = not self.verify_workers
            if self.stop_event.is_set() and last_worker:
                self.stop_activity_writer(
                    float(self.config.get("activity_shutdown_timeout_seconds", 10))
                )

    def wait_for_verification_workers(self, timeout: float) -> bool:
        deadline = time.monotonic() + max(0.0, timeout)
        current = threading.current_thread()
        while True:
            with self.verify_workers_lock:
                workers = [
                    worker for worker in self.verify_workers if worker is not current
                ]
            if not workers:
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            for worker in workers:
                worker.join(remaining)

    def shutdown(self) -> bool:
        self.stop_event.set()
        with self.control_gate:
            pass
        verification_timeout = float(
            self.config.get(
                "verification_shutdown_timeout_seconds",
                float(self.config.get("verify_window_seconds", 4))
                + float(self.config.get("event_notify_timeout_seconds", 10))
                + 10,
            )
        )
        if not self.wait_for_verification_workers(verification_timeout):
            logging.error(
                "verification workers did not stop within %.1fs; activity writer remains open",
                verification_timeout,
            )
            return False
        activity_timeout = float(
            self.config.get("activity_shutdown_timeout_seconds", 10)
        )
        if not self.stop_activity_writer(activity_timeout):
            logging.error(
                "activity writer did not drain within %.1fs",
                activity_timeout,
            )
            return False
        return True

    def should_skip_for_cooldown(self) -> bool:
        return self.cooldown_reason() is not None

    def cooldown_reason(self) -> str | None:
        now = time.monotonic()
        pass_cooldown = float(self.config.get("cooldown_seconds_after_pass", 30))
        lock_cooldown = self.config["cooldown_seconds_after_lock"]
        camera_error_cooldown = self.config["camera_error_cooldown_seconds"]
        if now - self.last_pass_at < pass_cooldown:
            return "recent_owner_pass"
        if now - self.last_lock_at < lock_cooldown:
            return "recent_lock"
        if now - self.last_camera_error_at < camera_error_cooldown:
            return "recent_camera_error"
        return None

    def on_input(self, source: str) -> None:
        with self.control_gate:
            if self.stop_event.is_set() or not self.protection_enabled:
                return
            if self.mode == "presence_guard":
                self.on_presence_guard_input(source)
                return
            if self.should_skip_for_cooldown() or not self.protection_enabled:
                return
            if not self.verify_lock.acquire(blocking=False):
                return
            if not self.protection_enabled:
                self.verify_lock.release()
                return
            self.start_verification_worker(source)

    def on_presence_guard_input(self, source: str) -> None:
        with self.control_gate:
            if self.stop_event.is_set() or not self.protection_enabled:
                return
            now = time.monotonic()
            if not self.protection_enabled:
                return
            idle_seconds = float(self.config.get("idle_seconds_before_armed", 60))
            idle_elapsed = now - self.last_activity_at

            if self.armed or idle_elapsed >= idle_seconds:
                cooldown_reason = self.cooldown_reason()
                if not self.protection_enabled:
                    return
                if cooldown_reason is not None:
                    logging.info(
                        "presence guard input skipped source=%s reason=%s",
                        source,
                        cooldown_reason,
                    )

                    def allow_cooldown() -> None:
                        self.last_activity_at = now
                        self.armed = False
                        self.persist_state(
                            {
                                "status": "active",
                                "mode": self.mode,
                                "armed": False,
                                "last_input_source": source,
                                "action": "allow_cooldown",
                                "cooldown_reason": cooldown_reason,
                            }
                        )

                    self.run_active_action(allow_cooldown)
                    return
                self.armed = True
                if not self.verify_lock.acquire(blocking=False):
                    logging.info(
                        "presence guard input skipped source=%s reason=verify_busy", source
                    )
                    return
                if not self.protection_enabled:
                    self.verify_lock.release()
                    self.armed = False
                    return
                logging.info("presence guard verification queued source=%s", source)
                self.start_verification_worker(source)
                return

            self.last_activity_at = now
            update_interval = float(
                self.config.get("active_state_update_interval_seconds", 10)
            )
            if now - self.last_active_state_at >= update_interval:

                def write_active_input() -> None:
                    self.last_active_state_at = now
                    self.persist_state(
                        {
                            "status": "active",
                            "mode": self.mode,
                            "armed": False,
                            "last_input_source": source,
                            "action": "skip_verify_active",
                        }
                    )

                self.run_active_action(write_active_input)

    def verify_and_act(self, source: str) -> None:
        try:
            logging.info("input detected source=%s mode=%s", source, self.mode)
            if not self.write_active_state(
                {
                    "status": "verifying",
                    "mode": self.mode,
                    "armed": self.armed,
                    "last_input_source": source,
                }
            ):
                return
            try:
                active, result = self.run_active_action(
                    lambda: verify_current_user(self.config, self.owner_encoding)
                )
            except Exception as exc:
                logging.exception("verification failed")
                self.handle_camera_error(str(exc))
                return
            if not active:
                return

            logging.info(
                "verify result decision=%s owner=%s stranger=%s no_face=%s frames=%s reason=%s",
                result.decision,
                result.owner_hits,
                result.stranger_hits,
                result.no_face_hits,
                result.frames_checked,
                result.reason,
            )
            self.handle_result(result)
        finally:
            if self.verify_lock.locked():
                self.verify_lock.release()

    def handle_result(self, result: VerifyResult) -> None:
        state = {
            "status": "verified",
            "mode": self.mode,
            "armed": self.armed,
            "last_decision": result.decision,
            "last_reason": result.reason,
            "owner_hits": result.owner_hits,
            "stranger_hits": result.stranger_hits,
            "no_face_hits": result.no_face_hits,
            "frames_checked": result.frames_checked,
        }
        if result.decision == "owner":
            def accept_owner() -> None:
                self.last_pass_at = time.monotonic()
                self.last_activity_at = time.monotonic()
                self.armed = False
                self.persist_state({**state, "armed": False, "action": "allow"})

            active, _ = self.run_active_action(accept_owner)
            if not active:
                return
            self.record_activity(
                "owner_verified",
                "已确认本人",
                "识别通过，继续使用",
                "success",
                {
                    "owner_hits": result.owner_hits,
                    "stranger_hits": result.stranger_hits,
                    "no_face_hits": result.no_face_hits,
                    "frames_checked": result.frames_checked,
                },
            )
            return

        should_lock = self.mode == "strict" or (
            self.mode == "balanced" and result.decision == "stranger"
        )
        if self.mode == "presence_guard":
            should_lock = self.armed and (
                result.decision == "stranger"
                or bool(self.config.get("lock_on_unknown_when_armed", True))
            )
        if should_lock:
            if not self.write_active_state({**state, "action": "lock"}):
                return
            failure_event = self.build_activity_event(
                "verification_failed",
                "验证未通过",
                "未确认本人，准备锁屏",
                "warning",
                {
                    "decision": result.decision,
                    "reason": result.reason,
                    "owner_hits": result.owner_hits,
                    "stranger_hits": result.stranger_hits,
                    "no_face_hits": result.no_face_hits,
                    "frames_checked": result.frames_checked,
                },
            )
            self.lock(result.decision, preceding_activity=failure_event)
        else:
            self.write_active_state({**state, "action": "observe"})

    def handle_camera_error(self, error: str) -> None:
        logging.warning("camera unavailable; allowing input without locking error=%s", error)
        def allow_camera_error() -> None:
            self.last_camera_error_at = time.monotonic()
            self.last_activity_at = time.monotonic()
            self.armed = False
            self.persist_state(
                {
                    "status": "camera_unavailable",
                    "mode": self.mode,
                    "armed": False,
                    "action": "allow_camera_unavailable",
                    "lock_on_camera_error": self.config["lock_on_camera_error"],
                    "camera_error_cooldown_seconds": self.config[
                        "camera_error_cooldown_seconds"
                    ],
                    "error": error,
                    "camera_error_at": now_iso(),
                }
            )

        active, _ = self.run_active_action(allow_camera_error)
        if not active:
            return
        self.record_activity(
            "camera_unavailable",
            "相机不可用，已保持解锁",
            error,
            "warning",
        )

    def lock(
        self,
        reason: str,
        *,
        preceding_activity: dict[str, Any] | None = None,
    ) -> str:
        previous_last_lock_at = self.last_lock_at

        def begin_lock() -> None:
            self.last_lock_at = time.monotonic()

        active, _ = self.run_active_action(begin_lock)
        if not active:
            return "paused"
        logging.warning("locking screen reason=%s mode=%s", reason, self.mode)
        evidence_path: Path | None = None
        lock_state: dict[str, Any] = {
            "status": "locking",
            "lock_reason": reason,
            "locked_at": now_iso(),
            "lock_succeeded": None,
        }
        if bool(self.config.get("capture_camera_on_lock", True)):
            try:
                active, evidence_path = self.run_active_action(
                    lambda: self.capture_camera_evidence(reason)
                )
                if not active:
                    self.last_lock_at = previous_last_lock_at
                    return "paused"
                logging.warning("camera evidence saved path=%s", evidence_path)
                lock_state["camera_evidence_path"] = str(evidence_path)
            except Exception as exc:
                if not self.protection_is_active():
                    self.last_lock_at = previous_last_lock_at
                    return "paused"
                logging.exception("camera evidence capture failed")
                lock_state["camera_evidence_error"] = str(exc)
        if evidence_path is not None and bool(self.config.get("allow_owner_from_final_evidence", True)):
            active, match_result = self.run_active_action(
                lambda: evidence_matches_owner(
                    self.config, self.owner_encoding, evidence_path
                )
            )
            if not active:
                self.last_lock_at = previous_last_lock_at
                return "paused"
            matched, score = match_result
            lock_state["final_evidence_owner_score"] = score
            if matched:
                def accept_final_owner() -> None:
                    self.last_pass_at = time.monotonic()
                    self.last_activity_at = time.monotonic()
                    self.armed = False
                    self.persist_state(
                        {
                            **lock_state,
                            "status": "verified",
                            "armed": False,
                            "action": "allow_final_camera_evidence",
                            "lock_reason": reason,
                        }
                    )

                active, _ = self.run_active_action(accept_final_owner)
                if not active:
                    self.last_lock_at = previous_last_lock_at
                    return "paused"
                logging.warning(
                    "final camera evidence matched owner; canceling lock reason=%s score=%.4f",
                    reason,
                    score,
                )
                if preceding_activity is not None:
                    self.enqueue_activity_event(preceding_activity)
                self.queue_activity(
                    "owner_verified",
                    "已确认本人",
                    "最终照片确认本人，已取消锁屏",
                    "success",
                    {"reason": reason, "score": score},
                )
                return "owner"
        if bool(self.config.get("capture_screen_on_lock", False)):
            try:
                active, screen_evidence_path = self.run_active_action(
                    lambda: self.capture_screen_evidence(reason)
                )
                if not active:
                    self.last_lock_at = previous_last_lock_at
                    return "paused"
                logging.warning("screen evidence saved path=%s", screen_evidence_path)
                lock_state["screen_evidence_path"] = str(screen_evidence_path)
                if evidence_path is None:
                    evidence_path = screen_evidence_path
            except Exception as exc:
                if not self.protection_is_active():
                    self.last_lock_at = previous_last_lock_at
                    return "paused"
                logging.exception("screen evidence capture failed")
                lock_state["screen_evidence_error"] = str(exc)
        if not self.write_active_state(lock_state):
            self.last_lock_at = previous_last_lock_at
            return "paused"
        try:
            with self.control_gate:
                generation = self.control_generation
                if not self.protection_enabled:
                    return "paused"
                lock_screen(dry_run=self.mode == "observe")
                logging.warning(
                    "lock command completed reason=%s mode=%s", reason, self.mode
                )
                if preceding_activity is not None:
                    self.enqueue_activity_event(preceding_activity)
                if self.mode != "observe":
                    self.queue_activity(
                        "screen_locked",
                        "已触发锁屏",
                        "识别结果触发锁屏",
                        "critical",
                        {"reason": reason},
                    )
                active = (
                    bool(self.protection_enabled)
                    and generation == self.control_generation
                )
                if active and self.mode != "observe":
                    self.persist_state({"lock_succeeded": True})
            if not active:
                return "paused"
        except Exception as exc:
            logging.exception("lock command failed")
            if not self.write_active_state(
                {
                    "status": "lock_error",
                    "lock_reason": reason,
                    "error": str(exc),
                    "lock_succeeded": False,
                }
            ):
                return "paused"
            if preceding_activity is not None:
                self.enqueue_activity_event(preceding_activity)
            self.notify_lock(reason, evidence_path)
            return "error"

        def complete_lock() -> None:
            self.armed = False
            self.last_activity_at = time.monotonic()

        active, _ = self.run_active_action(complete_lock)
        if not active:
            return "paused"
        if not self.protection_is_active():
            return "paused"
        self.notify_lock(reason, evidence_path)
        if not self.write_active_state(
            {
                "status": "locked",
                "armed": False,
                "lock_reason": reason,
                "action": "cooldown_after_lock",
                "cooldown_seconds_after_lock": self.config[
                    "cooldown_seconds_after_lock"
                ],
                "lock_command_completed_at": now_iso(),
            }
        ):
            return "paused"
        return "observe" if self.mode == "observe" else "locked"

    def notify_lock(self, reason: str, evidence_path: Path | None) -> None:
        if not self.protection_is_active():
            return
        try:
            result = notify_lock_event(self.config, reason, evidence_path)
        except Exception as exc:
            logging.exception("event notification failed")
            self.write_active_state(
                {"status": "event_notify_error", "lock_reason": reason, "error": str(exc)}
            )
            return
        if not self.protection_is_active():
            return
        if result is not None:
            result_summary = result if isinstance(result, dict) else {"ok": True}
            logging.warning(
                "event notification queued reason=%s evidence=%s result=%s",
                reason,
                evidence_path,
                result_summary,
            )
            self.write_active_state(
                {
                    "status": "event_queued",
                    "lock_reason": reason,
                    "event_queued_at": now_iso(),
                    "event_result": result_summary,
                }
            )

    def run(self) -> None:
        try:
            from pynput import keyboard, mouse
        except ImportError as exc:
            raise RuntimeError("Missing input dependency. Run scripts/bootstrap.sh first.") from exc

        initial_state = {
            "status": "running",
            "mode": self.mode,
            "armed": self.armed,
            "started_at": now_iso(),
            "owner_profile": str(self.runtime_paths.owner_face_path),
            "lock_on_camera_error": self.config["lock_on_camera_error"],
            "cooldown_seconds_after_lock": self.config[
                "cooldown_seconds_after_lock"
            ],
            "camera_error_cooldown_seconds": self.config[
                "camera_error_cooldown_seconds"
            ],
        }
        if not self.protection_enabled:
            initial_state.update(
                {
                    "status": "paused",
                    "action": "allow_paused",
                    "heartbeat": "paused",
                }
            )
        self.persist_replacement_state(initial_state)
        logging.info("mac-face-lock-agent started mode=%s", self.mode)

        self.mouse_listener = mouse.Listener(
            on_move=lambda *_: self.on_input("mouse_move"),
            on_click=lambda *_: self.on_input("mouse_click"),
            on_scroll=lambda *_: self.on_input("mouse_scroll"),
        )
        self.keyboard_listener = keyboard.Listener(
            on_press=lambda *_: self.on_input("keyboard")
        )
        self.mouse_listener.start()
        self.keyboard_listener.start()

        try:
            while not self.stop_event.wait(1):
                self.tick()
        finally:
            self.mouse_listener.stop()
            self.keyboard_listener.stop()
            shutdown_complete = self.shutdown()
            self.persist_state({"status": "stopped", "stopped_at": now_iso()})
            logging.info(
                "mac-face-lock-agent stopped shutdown_complete=%s",
                shutdown_complete,
            )

    def stop(self, *_: object) -> None:
        self.stop_event.set()

    def tick(self) -> None:
        if not self.input_listeners_alive():
            logging.error("input listener stopped unexpectedly; exiting for launchd restart")
            self.persist_state(
                {
                    "status": "input_listener_error",
                    "mode": self.mode,
                    "armed": self.armed,
                    "action": "restart_required",
                }
            )
            self.stop_event.set()
            return

        self.refresh_control_state()
        if not self.protection_enabled:
            now = time.monotonic()
            update_interval = float(
                self.config.get("active_state_update_interval_seconds", 10)
            )
            if now - self.last_active_state_at >= update_interval:
                self.last_active_state_at = now
                self.persist_state(
                    {
                        "status": "paused",
                        "mode": self.mode,
                        "armed": False,
                        "action": "allow_paused",
                        "heartbeat": "paused",
                    }
                )
            return

        if self.mode != "presence_guard":
            return

        system_idle_seconds = self.system_idle_seconds()

        if self.armed:
            if self.should_trigger_from_system_idle(system_idle_seconds):
                logging.info(
                    "system input detected while armed idle_seconds=%.2f",
                    system_idle_seconds,
                )
                self.on_presence_guard_input("system_idle")
                return

            now = time.monotonic()
            update_interval = float(self.config.get("active_state_update_interval_seconds", 10))
            if now - self.last_armed_state_at >= update_interval:
                self.last_armed_state_at = now
                self.persist_state(
                    {
                        "status": "armed",
                        "mode": self.mode,
                        "armed": True,
                        "action": "wait_for_input_verify",
                        "heartbeat": "armed",
                        "system_idle_seconds": round(system_idle_seconds, 1)
                        if system_idle_seconds is not None
                        else None,
                    }
                )
            return

        idle_seconds = float(self.config.get("idle_seconds_before_armed", 60))
        idle_elapsed = (
            system_idle_seconds
            if system_idle_seconds is not None
            else time.monotonic() - self.last_activity_at
        )
        if idle_elapsed < idle_seconds:
            now = time.monotonic()
            if system_idle_seconds is not None:
                self.last_activity_at = now - system_idle_seconds
            update_interval = float(self.config.get("active_state_update_interval_seconds", 10))
            if now - self.last_active_state_at >= update_interval:
                self.last_active_state_at = now
                self.persist_state(
                    {
                        "status": "active",
                        "mode": self.mode,
                        "armed": False,
                        "action": "wait_until_idle",
                        "heartbeat": "active",
                        "system_idle_seconds": round(idle_elapsed, 1),
                    }
                )
            return
        self.armed = True
        self.last_armed_state_at = time.monotonic()
        logging.info("presence guard armed idle_seconds=%.1f", idle_elapsed)
        self.persist_state(
            {
                "status": "armed",
                "mode": self.mode,
                "armed": True,
                "idle_seconds": round(idle_elapsed, 1),
                "action": "wait_for_input_verify",
                "heartbeat": "armed",
            }
        )
        self.record_activity(
            "protection_armed",
            "进入布防",
            "检测到持续空闲，下一次输入将验证身份",
            "info",
        )

    def input_listeners_alive(self) -> bool:
        listeners = [self.mouse_listener, self.keyboard_listener]
        return all(listener is not None and listener.is_alive() for listener in listeners)

    def system_idle_seconds(self) -> float | None:
        if not bool(self.config.get("system_idle_poll_enabled", True)):
            return None
        if self.system_idle_supported is False:
            return None
        try:
            import Quartz

            value = Quartz.CGEventSourceSecondsSinceLastEventType(
                Quartz.kCGEventSourceStateHIDSystemState,
                Quartz.kCGAnyInputEventType,
            )
        except Exception as exc:
            if self.system_idle_supported is not False:
                logging.warning("system idle polling unavailable error=%s", exc)
            self.system_idle_supported = False
            return None
        self.system_idle_supported = True
        return float(value)

    def should_trigger_from_system_idle(self, system_idle_seconds: float | None) -> bool:
        if system_idle_seconds is None:
            return False
        trigger_seconds = float(self.config.get("system_idle_trigger_seconds", 2.0))
        return system_idle_seconds <= trigger_seconds

    def capture_camera_evidence(self, reason: str) -> Path:
        camera_index = int(self.config.get("camera_index", 0))
        if self.explicit_runtime_paths:
            return capture_camera_evidence(
                reason,
                camera_index=camera_index,
                evidence_dir=self.runtime_paths.evidence_dir,
            )
        return capture_camera_evidence(reason, camera_index=camera_index)

    def capture_screen_evidence(self, reason: str) -> Path:
        if self.explicit_runtime_paths:
            return capture_screen_evidence(
                reason,
                evidence_dir=self.runtime_paths.evidence_dir,
            )
        return capture_screen_evidence(reason)


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def configure_logging(config: dict[str, Any], log_path: Path = LOG_PATH) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    level_name = str(config.get("log_level", "info")).upper()
    logging.basicConfig(
        level=getattr(logging, level_name, logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(log_path), logging.StreamHandler()],
    )


def main(
    paths: RuntimePaths = RUNTIME_PATHS,
    on_started: Callable[[], None] | None = None,
) -> int:
    paths.ensure_writable_directories()
    config = load_config(paths.config_path)
    log_path = paths.logs_dir / "agent.log"
    pid_path = paths.logs_dir / "agent.pid"
    configure_logging(config, log_path)
    pid_path.write_text(str(__import__("os").getpid()), encoding="utf-8")

    agent = FaceLockAgent(config, runtime_paths=paths)
    signal.signal(signal.SIGTERM, agent.stop)
    signal.signal(signal.SIGINT, agent.stop)
    try:
        if on_started is not None:
            on_started()
        agent.run()
    finally:
        try:
            pid_path.unlink()
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
