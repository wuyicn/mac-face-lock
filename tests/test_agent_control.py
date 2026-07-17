import os
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from agent import FaceLockAgent, probe_agent_permissions
from control_store import read_control, write_control
from face_verifier import VerifyResult
from runtime_paths import RuntimePaths


def wait_until(predicate, timeout=1.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return bool(predicate())


class FakeListener:
    def __init__(self, **callbacks: object) -> None:
        self.callbacks = callbacks
        self.ready = False

    def start(self) -> None:
        pass

    def wait(self) -> None:
        self.ready = True

    def stop(self) -> None:
        pass

    def is_alive(self) -> bool:
        return True


class InlineActivityWriter:
    def __init__(self, append_fn, path: Path) -> None:
        self.append_fn = append_fn
        self.path = path

    def enqueue(self, event):
        try:
            metadata = event["metadata"]
            args = (
                event["event_type"],
                event["title"],
                event["detail"],
                event["severity"],
            )
            if metadata is None:
                self.append_fn(*args, path=self.path)
            else:
                self.append_fn(*args, metadata, path=self.path)
        except Exception:
            return False
        return True

    def stop(self, _timeout=1.0) -> bool:
        return True


class AgentControlTests(unittest.TestCase):
    def test_agent_permission_probe_checks_authorization_without_opening_camera(
        self,
    ) -> None:
        capture_device = types.SimpleNamespace(
            authorizationStatusForMediaType_=lambda _media_type: 3
        )
        av_foundation = types.ModuleType("AVFoundation")
        av_foundation.AVMediaTypeVideo = "video"
        av_foundation.AVAuthorizationStatusAuthorized = 3
        av_foundation.AVCaptureDevice = capture_device
        quartz = types.ModuleType("Quartz")
        quartz.CGPreflightListenEventAccess = lambda: False
        application_services = types.ModuleType("ApplicationServices")
        application_services.AXIsProcessTrusted = lambda: True

        real_import = __import__

        def import_probe(name, *args, **kwargs):
            if name == "AVFoundation":
                return av_foundation
            if name == "Quartz":
                return quartz
            if name == "ApplicationServices":
                return application_services
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=import_probe):
            readiness = probe_agent_permissions()

        self.assertEqual(
            readiness,
            {
                "camera_ready": True,
                "input_monitoring_ready": False,
                "accessibility_ready": True,
            },
        )

    def test_agent_permission_request_uses_agent_owned_public_prompt_apis(self) -> None:
        camera_statuses = iter([0, 3])
        camera_requests = []
        input_requests = []
        accessibility_options = []

        capture_device = types.SimpleNamespace(
            authorizationStatusForMediaType_=lambda _media_type: next(camera_statuses),
            requestAccessForMediaType_completionHandler_=lambda media_type, completion: (
                camera_requests.append(media_type),
                completion(True),
            ),
        )
        av_foundation = types.ModuleType("AVFoundation")
        av_foundation.AVMediaTypeVideo = "video"
        av_foundation.AVAuthorizationStatusNotDetermined = 0
        av_foundation.AVAuthorizationStatusAuthorized = 3
        av_foundation.AVCaptureDevice = capture_device
        quartz = types.ModuleType("Quartz")
        quartz.CGPreflightListenEventAccess = lambda: False
        quartz.CGRequestListenEventAccess = lambda: input_requests.append(True) or True
        application_services = types.ModuleType("ApplicationServices")
        application_services.kAXTrustedCheckOptionPrompt = "prompt"
        application_services.AXIsProcessTrusted = lambda: False
        application_services.AXIsProcessTrustedWithOptions = (
            lambda options: accessibility_options.append(options) or True
        )

        real_import = __import__

        def import_probe(name, *args, **kwargs):
            if name == "AVFoundation":
                return av_foundation
            if name == "Quartz":
                return quartz
            if name == "ApplicationServices":
                return application_services
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=import_probe):
            readiness = probe_agent_permissions(
                request=True,
                camera_request_timeout_seconds=0.1,
            )

        self.assertEqual(camera_requests, ["video"])
        self.assertEqual(input_requests, [True])
        self.assertEqual(accessibility_options, [{"prompt": True}])
        self.assertEqual(
            readiness,
            {
                "camera_ready": True,
                "input_monitoring_ready": True,
                "accessibility_ready": True,
            },
        )

    def test_agent_permission_request_keeps_denied_permissions_false(self) -> None:
        capture_device = types.SimpleNamespace(
            authorizationStatusForMediaType_=lambda _media_type: 2,
            requestAccessForMediaType_completionHandler_=lambda *_args: self.fail(
                "denied camera permission was requested again"
            ),
        )
        av_foundation = types.ModuleType("AVFoundation")
        av_foundation.AVMediaTypeVideo = "video"
        av_foundation.AVAuthorizationStatusNotDetermined = 0
        av_foundation.AVAuthorizationStatusAuthorized = 3
        av_foundation.AVCaptureDevice = capture_device
        quartz = types.ModuleType("Quartz")
        quartz.CGPreflightListenEventAccess = lambda: False
        quartz.CGRequestListenEventAccess = lambda: False
        application_services = types.ModuleType("ApplicationServices")
        application_services.kAXTrustedCheckOptionPrompt = "prompt"
        application_services.AXIsProcessTrusted = lambda: False
        application_services.AXIsProcessTrustedWithOptions = lambda _options: False

        real_import = __import__

        def import_probe(name, *args, **kwargs):
            if name == "AVFoundation":
                return av_foundation
            if name == "Quartz":
                return quartz
            if name == "ApplicationServices":
                return application_services
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=import_probe):
            readiness = probe_agent_permissions(request=True)

        self.assertEqual(
            readiness,
            {
                "camera_ready": False,
                "input_monitoring_ready": False,
                "accessibility_ready": False,
            },
        )

    def test_agent_camera_permission_request_completion_is_bounded(self) -> None:
        capture_device = types.SimpleNamespace(
            authorizationStatusForMediaType_=lambda _media_type: 0,
            requestAccessForMediaType_completionHandler_=lambda *_args: None,
        )
        av_foundation = types.ModuleType("AVFoundation")
        av_foundation.AVMediaTypeVideo = "video"
        av_foundation.AVAuthorizationStatusNotDetermined = 0
        av_foundation.AVAuthorizationStatusAuthorized = 3
        av_foundation.AVCaptureDevice = capture_device
        quartz = types.ModuleType("Quartz")
        quartz.CGPreflightListenEventAccess = lambda: True
        quartz.CGRequestListenEventAccess = lambda: True
        application_services = types.ModuleType("ApplicationServices")
        application_services.kAXTrustedCheckOptionPrompt = "prompt"
        application_services.AXIsProcessTrusted = lambda: True
        application_services.AXIsProcessTrustedWithOptions = lambda _options: True

        real_import = __import__

        def import_probe(name, *args, **kwargs):
            if name == "AVFoundation":
                return av_foundation
            if name == "Quartz":
                return quartz
            if name == "ApplicationServices":
                return application_services
            return real_import(name, *args, **kwargs)

        started = time.monotonic()
        with patch("builtins.__import__", side_effect=import_probe):
            readiness = probe_agent_permissions(
                request=True,
                camera_request_timeout_seconds=0.01,
            )

        self.assertLess(time.monotonic() - started, 0.2)
        self.assertFalse(readiness["camera_ready"])

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        directory = Path(self.temporary_directory.name)
        self.control_path = directory / "control.json"
        self.activity_path = directory / "activity.jsonl"

        self.load_owner_encoding = patch(
            "agent.load_owner_encoding", return_value=object()
        ).start()
        self.write_state = patch("agent.write_state").start()
        self.append_activity = patch(
            "agent.append_activity", create=True
        ).start()
        self.addCleanup(patch.stopall)
        self.addCleanup(self.temporary_directory.cleanup)

    def make_agent(self, **config: object) -> FaceLockAgent:
        return FaceLockAgent(
            {"mode": "presence_guard", **config},
            control_path=self.control_path,
            activity_path=self.activity_path,
            activity_writer=InlineActivityWriter(
                self.append_activity,
                self.activity_path,
            ),
        )

    def make_real_writer_agent(self, **config: object) -> FaceLockAgent:
        agent = FaceLockAgent(
            {"mode": "presence_guard", **config},
            control_path=self.control_path,
            activity_path=self.activity_path,
        )
        self.addCleanup(lambda: (agent.stop(), agent.shutdown()))
        return agent

    def notification_config(self) -> dict[str, object]:
        script_path = Path(self.temporary_directory.name) / "notify.sh"
        script_path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        script_path.chmod(0o700)
        return {
            "event_notify_on_lock": True,
            "event_notify_script": str(script_path),
        }

    def test_missing_control_defaults_to_enabled(self) -> None:
        agent = self.make_agent()

        self.assertTrue(agent.protection_enabled)

    def test_explicit_source_paths_propagate_enabled_control_fallback(self) -> None:
        root = Path(self.temporary_directory.name) / "source"
        paths = RuntimePaths.for_source(root)
        agent = FaceLockAgent(
            {"mode": "presence_guard"},
            runtime_paths=paths,
            activity_writer=InlineActivityWriter(
                self.append_activity,
                paths.activity_path,
            ),
        )

        self.assertEqual(agent.control_path, paths.control_path)
        self.assertTrue(agent.protection_enabled)

    def test_release_paths_propagate_disabled_control_fallback(self) -> None:
        root = Path(self.temporary_directory.name)
        paths = RuntimePaths.for_release(
            root / "resources",
            root / "support",
        )
        agent = FaceLockAgent(
            {"mode": "presence_guard"},
            runtime_paths=paths,
            activity_writer=InlineActivityWriter(
                self.append_activity,
                paths.activity_path,
            ),
        )

        self.assertEqual(agent.control_path, paths.control_path)
        self.assertFalse(agent.protection_enabled)

    def test_disabling_protection_pauses_and_emits_one_event(self) -> None:
        agent = self.make_agent()
        agent.armed = True
        write_control(False, self.control_path)

        agent.refresh_control_state()

        self.assertFalse(agent.protection_enabled)
        self.assertFalse(agent.armed)
        self.write_state.assert_called_once_with(
            {
                "status": "paused",
                "mode": "presence_guard",
                "armed": False,
                "action": "allow_paused",
                "heartbeat": "paused",
            }
        )
        self.append_activity.assert_called_once_with(
            "protection_paused",
            "已暂停保护",
            "不会布防、验证或锁屏",
            "warning",
            path=self.activity_path,
        )

    def test_unchanged_disabled_control_does_not_duplicate_event(self) -> None:
        agent = self.make_agent()
        write_control(False, self.control_path)
        agent.refresh_control_state()
        self.write_state.reset_mock()
        self.append_activity.reset_mock()

        agent.refresh_control_state()

        self.write_state.assert_not_called()
        self.append_activity.assert_not_called()

    def test_reenabling_protection_resets_activity_and_emits_one_event(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent()
        agent.armed = True
        agent.last_activity_at = -1.0
        write_control(True, self.control_path)

        with patch("agent.time.monotonic", return_value=123.0):
            agent.refresh_control_state()

        self.assertTrue(agent.protection_enabled)
        self.assertFalse(agent.armed)
        self.assertEqual(agent.last_activity_at, 123.0)
        self.write_state.assert_called_once_with(
            {
                "status": "active",
                "mode": "presence_guard",
                "armed": False,
                "action": "wait_until_idle",
                "heartbeat": "active",
            }
        )
        self.append_activity.assert_called_once_with(
            "protection_resumed",
            "已恢复保护",
            "从正常使用状态重新开始计时",
            "info",
            path=self.activity_path,
        )

    def test_input_while_paused_never_starts_verification_thread(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent()

        with patch("agent.threading.Thread") as thread:
            agent.on_input("keyboard")

        thread.assert_not_called()
        self.assertFalse(agent.verify_lock.locked())

    def test_pause_crossing_regular_input_cooldown_never_starts_verification(self) -> None:
        agent = self.make_agent(mode="strict")

        def pause_during_cooldown_check():
            write_control(False, self.control_path)
            agent.refresh_control_state()
            return None

        with (
            patch.object(agent, "cooldown_reason", side_effect=pause_during_cooldown_check),
            patch("agent.threading.Thread") as thread,
        ):
            agent.on_input("keyboard")

        thread.assert_not_called()
        self.assertFalse(agent.verify_lock.locked())
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")

    def test_pause_crossing_zero_idle_presence_input_never_arms_or_verifies(self) -> None:
        agent = self.make_agent(idle_seconds_before_armed=0)

        def pause_during_cooldown_check():
            write_control(False, self.control_path)
            agent.refresh_control_state()
            return None

        with (
            patch.object(agent, "cooldown_reason", side_effect=pause_during_cooldown_check),
            patch("agent.threading.Thread") as thread,
        ):
            agent.on_input("keyboard")

        thread.assert_not_called()
        self.assertFalse(agent.verify_lock.locked())
        self.assertFalse(agent.armed)
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")

    def test_pause_crossing_presence_active_update_does_not_overwrite_paused(self) -> None:
        agent = self.make_agent(
            idle_seconds_before_armed=60,
            active_state_update_interval_seconds=0,
        )

        def pause_when_presence_input_reads_time() -> float:
            write_control(False, self.control_path)
            agent.refresh_control_state()
            return 10.0

        with (
            patch("agent.time.monotonic", side_effect=pause_when_presence_input_reads_time),
            patch("agent.threading.Thread") as thread,
        ):
            agent.on_input("mouse_move")

        thread.assert_not_called()
        self.assertFalse(agent.armed)
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")
        paused_index = next(
            index
            for index, call in enumerate(self.write_state.call_args_list)
            if call.args[0].get("status") == "paused"
        )
        self.assertFalse(
            any(
                call.args[0].get("status") == "active"
                for call in self.write_state.call_args_list[paused_index + 1 :]
            )
        )

    def test_tick_refreshes_paused_heartbeat_without_presence_guard_work(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent(active_state_update_interval_seconds=10)
        agent.last_active_state_at = 0.0

        with (
            patch.object(agent, "input_listeners_alive", return_value=True),
            patch.object(
                agent, "system_idle_seconds", return_value=None
            ) as system_idle_seconds,
            patch("agent.time.monotonic", return_value=20.0),
        ):
            agent.tick()

        self.write_state.assert_called_once_with(
            {
                "status": "paused",
                "mode": "presence_guard",
                "armed": False,
                "action": "allow_paused",
                "heartbeat": "paused",
            }
        )
        self.append_activity.assert_not_called()
        system_idle_seconds.assert_not_called()

    def test_tick_disabling_protection_writes_paused_state_once(self) -> None:
        agent = self.make_agent(active_state_update_interval_seconds=10)
        write_control(False, self.control_path)

        with (
            patch.object(agent, "input_listeners_alive", return_value=True),
            patch("agent.time.monotonic", return_value=20.0),
        ):
            agent.tick()

        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_count, 1)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")
        self.append_activity.assert_called_once_with(
            "protection_paused",
            "已暂停保护",
            "不会布防、验证或锁屏",
            "warning",
            path=self.activity_path,
        )

    def test_tick_reads_external_control_once(self) -> None:
        agent = self.make_agent(mode="observe")

        with (
            patch.object(agent, "input_listeners_alive", return_value=True),
            patch("agent.read_control", wraps=read_control) as mocked_read_control,
        ):
            agent.tick()

        mocked_read_control.assert_called_once()

    def test_run_starts_paused_without_fake_resumed_event(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent()
        agent.stop_event.set()
        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=FakeListener)
        pynput.mouse = types.SimpleNamespace(Listener=FakeListener)

        with (
            patch.dict("sys.modules", {"pynput": pynput}),
            patch(
                "agent.probe_agent_permissions",
                return_value={
                    "camera_ready": False,
                    "input_monitoring_ready": False,
                    "accessibility_ready": False,
                },
            ),
            patch("agent.replace_state") as replace_state,
        ):
            agent.run()

        replace_state.assert_called_once()
        initial_state = replace_state.call_args.args[0]
        self.assertEqual(initial_state["status"], "paused")
        self.assertEqual(initial_state["action"], "allow_paused")
        self.assertEqual(initial_state["heartbeat"], "paused")
        self.append_activity.assert_not_called()

    def test_run_publishes_agent_owned_permission_readiness_without_camera_capture(
        self,
    ) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent()
        agent.stop_event.set()
        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=FakeListener)
        pynput.mouse = types.SimpleNamespace(Listener=FakeListener)
        readiness = {
            "camera_ready": True,
            "input_monitoring_ready": False,
            "accessibility_ready": True,
        }

        with (
            patch.dict("sys.modules", {"pynput": pynput}),
            patch("agent.probe_agent_permissions", return_value=readiness) as probe,
            patch("agent.replace_state") as replace_state,
            patch("agent.verify_current_user") as verify_current_user,
        ):
            agent.run()

        probe.assert_called()
        verify_current_user.assert_not_called()
        initial_state = replace_state.call_args.args[0]
        self.assertEqual(initial_state["agent_pid"], os.getpid())
        self.assertIs(initial_state["camera_ready"], True)
        self.assertIs(initial_state["input_monitoring_ready"], False)
        self.assertIs(initial_state["accessibility_ready"], True)

    def test_run_publishes_readiness_only_after_input_listeners_start(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent()
        agent.stop_event.set()
        started = []
        ready = []

        class OrderingListener(FakeListener):
            def start(self) -> None:
                started.append(self)

            def wait(self) -> None:
                self.assert_started()
                ready.append(self)

            def assert_started(self) -> None:
                if self not in started:
                    raise AssertionError("wait called before listener start")

        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=OrderingListener)
        pynput.mouse = types.SimpleNamespace(Listener=OrderingListener)

        def publish_state(_state):
            self.assertEqual(
                len(started),
                2,
                "Agent readiness was published before both input listeners started",
            )
            self.assertEqual(
                len(ready),
                2,
                "Agent readiness was published before both input listeners were ready",
            )

        with (
            patch.dict("sys.modules", {"pynput": pynput}),
            patch(
                "agent.probe_agent_permissions",
                return_value={
                    "camera_ready": True,
                    "input_monitoring_ready": True,
                    "accessibility_ready": True,
                },
            ),
            patch("agent.replace_state", side_effect=publish_state),
        ):
            agent.run()

    def test_run_listener_readiness_failure_never_publishes_healthy_state(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent()
        published = []

        class FailingListener(FakeListener):
            waits = 0

            def wait(self) -> None:
                type(self).waits += 1
                if type(self).waits == 2:
                    raise RuntimeError("listener backend failed")
                super().wait()

        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=FailingListener)
        pynput.mouse = types.SimpleNamespace(Listener=FailingListener)

        with (
            patch.dict("sys.modules", {"pynput": pynput}),
            patch(
                "agent.probe_agent_permissions",
                return_value={
                    "camera_ready": True,
                    "input_monitoring_ready": True,
                    "accessibility_ready": True,
                },
            ),
            patch("agent.replace_state", side_effect=published.append),
            patch("agent.write_state", side_effect=published.append),
        ):
            with self.assertRaisesRegex(RuntimeError, "listener"):
                agent.run()

        self.assertFalse(
            any(
                state.get("camera_ready")
                and state.get("input_monitoring_ready")
                and state.get("accessibility_ready")
                for state in published
            )
        )
        self.assertEqual(published[-1]["status"], "input_listener_error")

    def test_run_listener_start_failure_stops_already_started_listener(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent()
        listeners = []

        class StartFailingListener(FakeListener):
            def __init__(self, **callbacks: object) -> None:
                super().__init__(**callbacks)
                self.stopped = False
                listeners.append(self)

            def start(self) -> None:
                if len([listener for listener in listeners if listener.ready]) == 1:
                    raise RuntimeError("listener start failed")
                self.ready = True

            def stop(self) -> None:
                self.stopped = True

        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=StartFailingListener)
        pynput.mouse = types.SimpleNamespace(Listener=StartFailingListener)

        with (
            patch.dict("sys.modules", {"pynput": pynput}),
            patch(
                "agent.probe_agent_permissions",
                return_value={
                    "camera_ready": True,
                    "input_monitoring_ready": True,
                    "accessibility_ready": True,
                },
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "listener"):
                agent.run()

        self.assertTrue(listeners[0].stopped)

    def test_run_listener_readiness_wait_has_bounded_timeout(self) -> None:
        write_control(False, self.control_path)
        agent = self.make_agent(listener_ready_timeout_seconds=0.01)
        release_wait = threading.Event()

        class BlockingListener(FakeListener):
            def wait(self) -> None:
                release_wait.wait(1)

        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=BlockingListener)
        pynput.mouse = types.SimpleNamespace(Listener=BlockingListener)

        started = time.monotonic()
        try:
            with (
                patch.dict("sys.modules", {"pynput": pynput}),
                patch(
                    "agent.probe_agent_permissions",
                    return_value={
                        "camera_ready": True,
                        "input_monitoring_ready": True,
                        "accessibility_ready": True,
                    },
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "timed out"):
                    agent.run()
        finally:
            release_wait.set()

        self.assertLess(time.monotonic() - started, 0.2)

    def test_tick_reprobes_permissions_and_publishes_revocation(self) -> None:
        agent = self.make_agent(permission_probe_interval_seconds=0)
        agent.mouse_listener = FakeListener()
        agent.keyboard_listener = FakeListener()
        agent.mouse_listener.ready = True
        agent.keyboard_listener.ready = True
        agent.permission_readiness = {
            "camera_ready": True,
            "input_monitoring_ready": True,
            "accessibility_ready": True,
        }
        agent.live_state_started = True

        with patch(
            "agent.probe_agent_permissions",
            return_value={
                "camera_ready": True,
                "input_monitoring_ready": False,
                "accessibility_ready": True,
            },
        ):
            agent.tick()

        published = self.write_state.call_args.args[0]
        self.assertFalse(published["input_monitoring_ready"])
        self.assertTrue(published["camera_ready"])
        self.assertTrue(published["accessibility_ready"])

    def test_entering_armed_state_emits_activity_event(self) -> None:
        agent = self.make_agent(idle_seconds_before_armed=60)
        agent.last_activity_at = 0.0

        with (
            patch.object(agent, "input_listeners_alive", return_value=True),
            patch.object(agent, "system_idle_seconds", return_value=None),
            patch("agent.time.monotonic", return_value=120.0),
        ):
            agent.tick()

        self.append_activity.assert_called_once()
        event = self.append_activity.call_args
        self.assertEqual(event.args[0], "protection_armed")
        self.assertEqual(event.args[1], "进入布防")
        self.assertEqual(event.args[3], "info")
        self.assertEqual(event.kwargs["path"], self.activity_path)

    def test_owner_result_emits_success_with_hit_metadata(self) -> None:
        agent = self.make_agent()
        result = VerifyResult("owner", 2, 0, 0, 2, "owner_threshold")

        agent.handle_result(result)

        self.append_activity.assert_called_once()
        event = self.append_activity.call_args
        self.assertEqual(event.args[:4], (
            "owner_verified",
            "已确认本人",
            "识别通过，继续使用",
            "success",
        ))
        self.assertEqual(
            event.args[4],
            {
                "owner_hits": 2,
                "stranger_hits": 0,
                "no_face_hits": 0,
                "frames_checked": 2,
            },
        )
        self.assertEqual(event.kwargs["path"], self.activity_path)

    def test_lock_runs_before_failed_verification_activity_persistence(self) -> None:
        agent = self.make_agent(
            mode="strict",
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
        )
        result = VerifyResult("stranger", 0, 3, 0, 3, "stranger_threshold")
        transitions: list[str] = []

        def persist_activity(event_type: str, *_args: object, **_kwargs: object) -> None:
            transitions.append(event_type)

        self.append_activity.side_effect = persist_activity

        def mark_lock_start(**_kwargs: object) -> None:
            transitions.append("lock")

        with (
            patch("agent.lock_screen", side_effect=mark_lock_start),
            patch.object(agent, "notify_lock"),
            patch("agent.logging.warning"),
        ):
            agent.handle_result(result)

        self.assertEqual(
            transitions,
            ["lock", "verification_failed", "screen_locked"],
        )

    def test_final_evidence_persists_failure_before_owner_cancellation(self) -> None:
        agent = self.make_agent(
            mode="strict",
            capture_camera_on_lock=True,
            capture_screen_on_lock=False,
            allow_owner_from_final_evidence=True,
        )
        result = VerifyResult("stranger", 0, 3, 0, 3, "stranger_threshold")
        evidence_path = Path(self.temporary_directory.name) / "owner.jpg"
        persisted_types: list[str] = []
        self.append_activity.side_effect = (
            lambda event_type, *_args, **_kwargs: persisted_types.append(event_type)
        )

        with (
            patch("agent.capture_camera_evidence", return_value=evidence_path),
            patch("agent.evidence_matches_owner", return_value=(True, 0.91)),
            patch("agent.lock_screen") as lock_screen,
            patch("agent.logging.warning"),
        ):
            agent.handle_result(result)

        lock_screen.assert_not_called()
        self.assertEqual(persisted_types, ["verification_failed", "owner_verified"])

    def test_activity_write_failure_does_not_prevent_lock(self) -> None:
        agent = self.make_agent(mode="strict")
        result = VerifyResult("stranger", 0, 3, 0, 3, "stranger_threshold")
        self.append_activity.side_effect = OSError("activity unavailable")

        with (
            patch.object(agent, "lock") as lock,
            patch("agent.logging.exception"),
        ):
            agent.handle_result(result)

        lock.assert_called_once()
        self.assertEqual(lock.call_args.args, ("stranger",))
        self.assertEqual(
            lock.call_args.kwargs["preceding_activity"]["event_type"],
            "verification_failed",
        )

    def test_stalled_activity_append_releases_verify_lock_and_allows_next_input(self) -> None:
        agent = self.make_real_writer_agent(
            mode="strict",
            cooldown_seconds_after_pass=0,
        )
        append_started = threading.Event()
        release_append = threading.Event()
        result = VerifyResult("owner", 2, 0, 0, 2, "owner_threshold")

        def stalled_append(*_args, **_kwargs):
            append_started.set()
            release_append.wait(1)

        self.append_activity.side_effect = stalled_append
        try:
            with patch("agent.verify_current_user", return_value=result) as verify:
                agent.on_input("keyboard")
                self.assertTrue(append_started.wait(1))
                self.assertTrue(
                    wait_until(lambda: not agent.verify_lock.locked(), timeout=0.1),
                    "telemetry append held verify_lock",
                )

                agent.on_input("mouse_click")

                self.assertTrue(wait_until(lambda: verify.call_count == 2))
        finally:
            release_append.set()

    def test_stalled_activity_append_does_not_block_tick_control_transition(self) -> None:
        agent = self.make_real_writer_agent(active_state_update_interval_seconds=10)
        append_started = threading.Event()
        release_append = threading.Event()
        tick_finished = threading.Event()

        def stalled_append(*_args, **_kwargs):
            append_started.set()
            release_append.wait(1)

        def run_tick():
            agent.tick()
            tick_finished.set()

        self.append_activity.side_effect = stalled_append
        write_control(False, self.control_path)
        try:
            with patch.object(agent, "input_listeners_alive", return_value=True):
                tick_thread = threading.Thread(target=run_tick)
                tick_thread.start()
                self.assertTrue(append_started.wait(1))
                self.assertTrue(
                    tick_finished.wait(0.1),
                    "telemetry append blocked tick/control",
                )
        finally:
            release_append.set()
            tick_thread.join(1)

    def test_activity_append_exception_drops_failed_item_and_advances(self) -> None:
        agent = self.make_real_writer_agent()
        persisted = []

        def append_with_failed_head(event_type, *_args, **_kwargs):
            if event_type == "first":
                raise OSError("activity unavailable")
            persisted.append(event_type)

        self.append_activity.side_effect = append_with_failed_head
        with patch("agent.logging.exception"):
            agent.record_activity("first", "first", "first", "warning")
            agent.record_activity("second", "second", "second", "info")

            self.assertTrue(wait_until(lambda: persisted == ["second"]))

    def test_activity_writer_preserves_fifo_order(self) -> None:
        agent = self.make_real_writer_agent()
        persisted = []
        all_written = threading.Event()

        def capture_order(event_type, *_args, **_kwargs):
            persisted.append(event_type)
            if len(persisted) == 3:
                all_written.set()

        self.append_activity.side_effect = capture_order
        agent.record_activity("first", "first", "first", "info")
        agent.record_activity("second", "second", "second", "warning")
        agent.record_activity("third", "third", "third", "critical")

        self.assertTrue(all_written.wait(1))
        self.assertEqual(persisted, ["first", "second", "third"])

    def test_activity_queue_overflow_drops_new_telemetry_without_blocking(self) -> None:
        agent = self.make_real_writer_agent(activity_queue_maxsize=1)
        append_started = threading.Event()
        release_append = threading.Event()
        persisted = []

        def stall_first(event_type, *_args, **_kwargs):
            persisted.append(event_type)
            if event_type == "first":
                append_started.set()
                release_append.wait(1)

        self.append_activity.side_effect = stall_first
        try:
            first_thread = threading.Thread(
                target=lambda: agent.record_activity(
                    "first", "first", "first", "info"
                )
            )
            first_thread.start()
            self.assertTrue(append_started.wait(1))

            with patch("agent.logging.warning") as warning:
                started = time.monotonic()
                agent.record_activity("second", "second", "second", "info")
                agent.record_activity("third", "third", "third", "info")
                self.assertLess(time.monotonic() - started, 0.1)
                warning.assert_called_once()
                self.assertIn("dropping telemetry", warning.call_args.args[0])
        finally:
            release_append.set()
            first_thread.join(1)

        self.assertTrue(wait_until(lambda: len(persisted) >= 2))
        self.assertEqual(persisted, ["first", "second"])

    def test_activity_writer_rejects_enqueue_after_stop_without_orphaning(self) -> None:
        agent = self.make_real_writer_agent()
        agent.stop_activity_writer()
        event = agent.build_activity_event(
            "after_stop",
            "after stop",
            "must be rejected",
            "warning",
        )

        with patch("agent.logging.warning") as warning:
            accepted = agent.enqueue_activity_event(event)

        self.assertFalse(accepted)
        warning.assert_called_once()
        self.assertTrue(agent.activity_writer.queue.empty())
        self.assertFalse(agent.activity_writer.thread.is_alive())

    def test_shutdown_waits_for_inflight_verification_then_drains_activity(self) -> None:
        agent = self.make_real_writer_agent(
            mode="strict",
            cooldown_seconds_after_pass=0,
        )
        run_started = threading.Event()
        verification_started = threading.Event()
        release_verification = threading.Event()
        run_finished = threading.Event()
        owner_persisted = threading.Event()
        result = VerifyResult("owner", 2, 0, 0, 2, "owner_threshold")
        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=FakeListener)
        pynput.mouse = types.SimpleNamespace(Listener=FakeListener)
        run_thread = None
        late_input_thread = None

        def blocking_verify(*_args):
            verification_started.set()
            release_verification.wait(2)
            return result

        def capture_activity(event_type, *_args, **_kwargs):
            if event_type == "owner_verified":
                owner_persisted.set()

        def run_agent():
            agent.run()
            run_finished.set()

        self.append_activity.side_effect = capture_activity
        try:
            with (
                patch.dict("sys.modules", {"pynput": pynput}),
                patch(
                    "agent.probe_agent_permissions",
                    return_value={
                        "camera_ready": False,
                        "input_monitoring_ready": False,
                        "accessibility_ready": False,
                    },
                ),
                patch("agent.replace_state", side_effect=lambda *_: run_started.set()),
                patch("agent.verify_current_user", side_effect=blocking_verify) as verify,
            ):
                run_thread = threading.Thread(target=run_agent)
                run_thread.start()
                self.assertTrue(run_started.wait(1))
                agent.on_input("keyboard")
                self.assertTrue(verification_started.wait(1))

                agent.stop()
                late_input_thread = threading.Thread(
                    target=lambda: agent.on_input("mouse_click")
                )
                late_input_thread.start()

                self.assertEqual(verify.call_count, 1)
                self.assertFalse(
                    run_finished.wait(0.1),
                    "shutdown stopped the activity writer before its producer",
                )
        finally:
            release_verification.set()
            if run_thread is not None:
                run_thread.join(2)
            if late_input_thread is not None:
                late_input_thread.join(1)

        self.assertTrue(run_finished.is_set())
        self.assertTrue(owner_persisted.is_set())
        self.assertFalse(agent.activity_writer.thread.is_alive())

    def test_pause_during_verification_prevents_lock_and_preserves_paused_state(self) -> None:
        agent = self.make_agent(mode="strict")
        result = VerifyResult("stranger", 0, 3, 0, 3, "stranger_threshold")

        def pause_then_return_result(*_args: object) -> VerifyResult:
            write_control(False, self.control_path)
            agent.refresh_control_state()
            return result

        with (
            patch("agent.verify_current_user", side_effect=pause_then_return_result),
            patch.object(agent, "lock") as lock,
        ):
            agent.verify_and_act("keyboard")

        lock.assert_not_called()
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")
        self.assertEqual(self.write_state.call_args.args[0]["action"], "allow_paused")

    def test_pause_during_preverify_state_write_skips_camera_verification(self) -> None:
        agent = self.make_agent(mode="strict")
        paused_state = {
            "status": "paused",
            "mode": "strict",
            "armed": False,
            "action": "allow_paused",
            "heartbeat": "paused",
        }

        def pause_during_state_write(payload: dict[str, object]) -> None:
            if payload.get("status") == "verifying":
                agent.protection_enabled = False
                self.write_state(paused_state)

        self.write_state.side_effect = pause_during_state_write
        with patch("agent.verify_current_user") as verify_current_user:
            agent.verify_and_act("keyboard")

        verify_current_user.assert_not_called()
        self.assertEqual(self.write_state.call_args.args[0], paused_state)
        self.append_activity.assert_not_called()

    def test_refresh_immediately_before_verify_state_write_is_not_overwritten(self) -> None:
        agent = self.make_agent(mode="strict")

        def pause_before_state_write(message: str, *_args: object) -> None:
            if message == "input detected source=%s mode=%s":
                write_control(False, self.control_path)
                agent.refresh_control_state()

        with (
            patch("agent.logging.info", side_effect=pause_before_state_write),
            patch("agent.verify_current_user") as verify_current_user,
        ):
            agent.verify_and_act("keyboard")

        verify_current_user.assert_not_called()
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")

    def test_pause_during_camera_failure_preserves_paused_state(self) -> None:
        agent = self.make_agent(lock_on_camera_error=False)

        def pause_then_fail(*_args: object) -> VerifyResult:
            write_control(False, self.control_path)
            agent.refresh_control_state()
            raise RuntimeError("camera denied")

        with (
            patch("agent.verify_current_user", side_effect=pause_then_fail),
            patch("agent.logging.exception"),
            patch("agent.logging.warning"),
        ):
            agent.verify_and_act("keyboard")

        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")
        self.assertEqual(self.write_state.call_args.args[0]["action"], "allow_paused")
        self.assertFalse(
            any(
                call.args[0].get("action") == "allow_camera_unavailable"
                for call in self.write_state.call_args_list
            )
        )

    def test_camera_error_fails_open_and_emits_warning(self) -> None:
        agent = self.make_agent(lock_on_camera_error=False)

        with (
            patch("agent.verify_current_user", side_effect=RuntimeError("camera denied")),
            patch.object(agent, "lock") as lock,
            patch("agent.logging.exception"),
            patch("agent.logging.warning"),
        ):
            agent.verify_and_act("keyboard")

        lock.assert_not_called()
        self.assertTrue(
            any(
                call.args[0].get("action") == "allow_camera_unavailable"
                for call in self.write_state.call_args_list
            )
        )
        self.append_activity.assert_called_once_with(
            "camera_unavailable",
            "相机不可用，已保持解锁",
            "camera denied",
            "warning",
            path=self.activity_path,
        )

    def test_legacy_camera_error_lock_setting_is_forced_fail_open(self) -> None:
        agent = self.make_agent(mode="strict", lock_on_camera_error=True)

        with (
            patch("agent.verify_current_user", side_effect=RuntimeError("camera denied")),
            patch.object(agent, "lock") as lock,
            patch("agent.logging.exception"),
            patch("agent.logging.warning"),
        ):
            agent.verify_and_act("keyboard")

        lock.assert_not_called()
        self.assertIs(agent.config["lock_on_camera_error"], False)
        camera_state = next(
            call.args[0]
            for call in self.write_state.call_args_list
            if call.args[0].get("status") == "camera_unavailable"
        )
        self.assertIs(camera_state["lock_on_camera_error"], False)

    def test_runtime_cooldowns_apply_300_second_floor_at_boundaries(self) -> None:
        cases = (
            ("missing", {}),
            ("zero", {"value": 0}),
            ("below-floor", {"value": 299}),
            ("at-floor", {"value": 300}),
            ("above-floor", {"value": 301}),
        )
        for key in (
            "cooldown_seconds_after_lock",
            "camera_error_cooldown_seconds",
        ):
            for name, case in cases:
                config = {} if "value" not in case else {key: case["value"]}
                with self.subTest(key=key, case=name):
                    agent = self.make_agent(**config)
                    self.assertEqual(agent.config.get(key), max(300, case.get("value", 300)))

    def test_runtime_cooldowns_reject_invalid_non_finite_and_overflow_values(self) -> None:
        invalid_values = (
            ("none", None),
            ("invalid-string", "not-a-number"),
            ("positive-infinity-string", "inf"),
            ("negative-infinity-string", "-inf"),
            ("nan-string", "nan"),
            ("json-overflow-number", 1e999),
            ("overflowing-integer", 10**10000),
        )
        for key in (
            "cooldown_seconds_after_lock",
            "camera_error_cooldown_seconds",
        ):
            for name, value in invalid_values:
                with self.subTest(key=key, case=name):
                    try:
                        agent = self.make_agent(**{key: value})
                    except Exception as exc:
                        self.fail(f"runtime normalization raised {type(exc).__name__}: {exc}")
                    self.assertEqual(agent.config[key], 300.0)

    def test_states_report_finite_cooldowns_for_non_finite_config(self) -> None:
        agent = self.make_agent(
            cooldown_seconds_after_lock="inf",
            camera_error_cooldown_seconds=1e999,
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
        )

        with (
            patch("agent.lock_screen"),
            patch.object(agent, "notify_lock"),
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")
            agent.handle_camera_error("camera denied")

        agent.stop_event.set()
        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=FakeListener)
        pynput.mouse = types.SimpleNamespace(Listener=FakeListener)
        with (
            patch.dict("sys.modules", {"pynput": pynput}),
            patch(
                "agent.probe_agent_permissions",
                return_value={
                    "camera_ready": False,
                    "input_monitoring_ready": False,
                    "accessibility_ready": False,
                },
            ),
            patch("agent.replace_state") as replace_state,
        ):
            agent.run()

        locked_state = next(
            call.args[0]
            for call in self.write_state.call_args_list
            if call.args[0].get("status") == "locked"
        )
        camera_state = next(
            call.args[0]
            for call in self.write_state.call_args_list
            if call.args[0].get("status") == "camera_unavailable"
        )
        initial_state = replace_state.call_args.args[0]
        self.assertEqual(locked_state["cooldown_seconds_after_lock"], 300.0)
        self.assertEqual(camera_state["camera_error_cooldown_seconds"], 300.0)
        self.assertEqual(initial_state["cooldown_seconds_after_lock"], 300.0)
        self.assertEqual(initial_state["camera_error_cooldown_seconds"], 300.0)

    def test_lock_and_camera_error_states_report_effective_cooldowns(self) -> None:
        agent = self.make_agent(
            cooldown_seconds_after_lock=0,
            camera_error_cooldown_seconds=299,
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
        )

        with (
            patch("agent.lock_screen"),
            patch.object(agent, "notify_lock"),
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")
            agent.handle_camera_error("camera denied")

        locked_state = next(
            call.args[0]
            for call in self.write_state.call_args_list
            if call.args[0].get("status") == "locked"
        )
        camera_state = next(
            call.args[0]
            for call in self.write_state.call_args_list
            if call.args[0].get("status") == "camera_unavailable"
        )
        self.assertEqual(locked_state["cooldown_seconds_after_lock"], 300)
        self.assertEqual(camera_state["camera_error_cooldown_seconds"], 300)

    def test_pause_during_camera_error_state_write_skips_later_activity(self) -> None:
        agent = self.make_agent(lock_on_camera_error=False)
        paused_state = {
            "status": "paused",
            "mode": "presence_guard",
            "armed": False,
            "action": "allow_paused",
            "heartbeat": "paused",
        }

        def pause_during_state_write(payload: dict[str, object]) -> None:
            if payload.get("status") == "camera_unavailable":
                agent.protection_enabled = False
                self.write_state(paused_state)

        self.write_state.side_effect = pause_during_state_write
        with patch("agent.logging.warning"):
            agent.handle_camera_error("camera denied")

        self.assertEqual(self.write_state.call_args.args[0], paused_state)
        self.append_activity.assert_not_called()

    def test_pause_immediately_before_lock_skips_lock_and_failure_activity(self) -> None:
        agent = self.make_agent(mode="strict")
        result = VerifyResult("stranger", 0, 3, 0, 3, "stranger_threshold")
        paused_state = {
            "status": "paused",
            "mode": "strict",
            "armed": False,
            "action": "allow_paused",
            "heartbeat": "paused",
        }

        def pause_during_state_write(payload: dict[str, object]) -> None:
            if payload.get("action") == "lock":
                agent.protection_enabled = False
                self.write_state(paused_state)

        self.write_state.side_effect = pause_during_state_write
        with patch.object(agent, "lock") as lock:
            agent.handle_result(result)

        lock.assert_not_called()
        self.assertEqual(self.write_state.call_args.args[0], paused_state)
        self.append_activity.assert_not_called()

    def test_pause_generation_change_before_lock_dispatch_skips_dispatch(self) -> None:
        agent = self.make_agent(
            mode="strict",
            capture_camera_on_lock=True,
            capture_screen_on_lock=False,
        )
        result = VerifyResult("stranger", 0, 3, 0, 3, "stranger_threshold")
        control_path = self.control_path

        class PauseOnThirdRead:
            def __init__(self) -> None:
                self.reads = 0

            def __bool__(self) -> bool:
                self.reads += 1
                if self.reads == 3:
                    write_control(False, control_path)
                    agent.refresh_control_state()
                return True

        agent.protection_enabled = PauseOnThirdRead()  # type: ignore[assignment]
        with (
            patch("agent.capture_camera_evidence") as capture_camera_evidence,
            patch("agent.lock_screen") as lock_screen,
        ):
            agent.handle_result(result)

        capture_camera_evidence.assert_not_called()
        lock_screen.assert_not_called()
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")

    def test_completed_lock_emits_critical_activity_with_reason(self) -> None:
        agent = self.make_agent(capture_camera_on_lock=False, capture_screen_on_lock=False)

        with (
            patch("agent.lock_screen") as lock_screen,
            patch.object(agent, "notify_lock"),
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        lock_screen.assert_called_once_with(dry_run=False)
        self.append_activity.assert_called_once_with(
            "screen_locked",
            "已触发锁屏",
            "识别结果触发锁屏",
            "critical",
            {"reason": "stranger"},
            path=self.activity_path,
        )

    def test_missing_notification_config_does_not_record_fake_success(self) -> None:
        agent = self.make_agent()
        self.assertNotIn("event_notify_on_lock", agent.config)

        with patch("event_notifier.subprocess.run") as run:
            agent.notify_lock("stranger", None)

        run.assert_not_called()
        for call in self.write_state.call_args_list:
            state = call.args[0]
            self.assertNotEqual(state.get("status"), "event_queued")
            self.assertNotIn("event_result", state)

    def test_successful_lock_marks_queued_notification_as_lock_succeeded(self) -> None:
        agent = self.make_agent(
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
            **self.notification_config(),
        )
        persisted: dict[str, object] = {}
        snapshots: list[dict[str, object]] = []

        def merge_state(update: dict[str, object]) -> None:
            persisted.update(update)
            snapshots.append(dict(persisted))

        self.write_state.side_effect = merge_state
        with (
            patch("agent.lock_screen"),
            patch("event_notifier._run_add_event", return_value={"queued": True}),
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        queued = next(state for state in snapshots if state.get("status") == "event_queued")
        self.assertIs(queued["lock_succeeded"], True)

    def test_failed_lock_preserves_failure_through_queued_notification(self) -> None:
        agent = self.make_agent(
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
            **self.notification_config(),
        )
        persisted: dict[str, object] = {}

        self.write_state.side_effect = persisted.update
        with (
            patch("agent.lock_screen", side_effect=OSError("lock denied")),
            patch("event_notifier._run_add_event", return_value={"queued": True}),
            patch("agent.logging.exception"),
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        self.assertEqual(persisted["status"], "event_queued")
        self.assertIs(persisted["lock_succeeded"], False)

    def test_failed_lock_preserves_failure_through_notification_error(self) -> None:
        agent = self.make_agent(
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
            **self.notification_config(),
        )
        persisted: dict[str, object] = {}

        self.write_state.side_effect = persisted.update
        with (
            patch("agent.lock_screen", side_effect=OSError("lock denied")),
            patch("event_notifier._run_add_event", side_effect=OSError("notify denied")),
            patch("agent.logging.exception"),
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        self.assertEqual(persisted["status"], "event_notify_error")
        self.assertIs(persisted["lock_succeeded"], False)

    def test_pause_during_lock_screen_return_preserves_paused_state(self) -> None:
        agent = self.make_agent(capture_camera_on_lock=False, capture_screen_on_lock=False)
        paused_state = {
            "status": "paused",
            "mode": "presence_guard",
            "armed": False,
            "action": "allow_paused",
            "heartbeat": "paused",
        }

        def pause_before_return(*_args: object, **_kwargs: object) -> None:
            agent.protection_enabled = False
            self.write_state(paused_state)

        with (
            patch("agent.lock_screen", side_effect=pause_before_return) as lock_screen,
            patch.object(agent, "notify_lock") as notify_lock,
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        lock_screen.assert_called_once_with(dry_run=False)
        notify_lock.assert_not_called()
        self.assertEqual(self.write_state.call_args.args[0], paused_state)
        self.append_activity.assert_called_once_with(
            "screen_locked",
            "已触发锁屏",
            "识别结果触发锁屏",
            "critical",
            {"reason": "stranger"},
            path=self.activity_path,
        )

    def test_completed_lock_history_precedes_serialized_pause_waiter(self) -> None:
        agent = self.make_agent(
            mode="strict",
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
        )
        persisted = []
        pause_attempting = threading.Event()
        pause_finished = threading.Event()
        lock_returned = threading.Event()
        original_run_active_action = agent.run_active_action
        failure_event = agent.build_activity_event(
            "verification_failed",
            "验证未通过",
            "未确认本人，准备锁屏",
            "warning",
        )

        self.append_activity.side_effect = (
            lambda event_type, *_args, **_kwargs: persisted.append(event_type)
        )

        def pause_after_lock():
            write_control(False, self.control_path)
            pause_attempting.set()
            agent.refresh_control_state()
            pause_finished.set()

        def complete_os_lock(**_kwargs):
            pause_thread = threading.Thread(target=pause_after_lock)
            pause_thread.start()
            self.assertTrue(pause_attempting.wait(1))
            lock_returned.set()

        def serialize_pause_after_action(action):
            result = original_run_active_action(action)
            if lock_returned.is_set() and not pause_finished.is_set():
                self.assertTrue(pause_finished.wait(1))
            return result

        with (
            patch.object(agent, "run_active_action", side_effect=serialize_pause_after_action),
            patch("agent.lock_screen", side_effect=complete_os_lock),
            patch.object(agent, "notify_lock"),
            patch("agent.logging.warning"),
        ):
            outcome = agent.lock("stranger", preceding_activity=failure_event)

        self.assertTrue(pause_finished.is_set())
        self.assertEqual(outcome, "paused")
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")
        self.assertEqual(
            persisted,
            ["verification_failed", "screen_locked", "protection_paused"],
        )

    def test_observe_dry_run_does_not_emit_screen_locked_activity(self) -> None:
        agent = self.make_agent(
            mode="observe",
            capture_camera_on_lock=False,
            capture_screen_on_lock=False,
        )

        with (
            patch("agent.lock_screen") as lock_screen,
            patch.object(agent, "notify_lock"),
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        lock_screen.assert_called_once_with(dry_run=True)
        self.assertFalse(
            any(
                call.args[0] == "screen_locked"
                for call in self.append_activity.call_args_list
            )
        )

    def test_final_owner_evidence_cancels_lock_and_emits_success(self) -> None:
        agent = self.make_agent(
            capture_camera_on_lock=True,
            capture_screen_on_lock=False,
            allow_owner_from_final_evidence=True,
        )
        evidence_path = Path(self.temporary_directory.name) / "owner.jpg"

        with (
            patch("agent.capture_camera_evidence", return_value=evidence_path),
            patch("agent.evidence_matches_owner", return_value=(True, 0.91)),
            patch("agent.lock_screen") as lock_screen,
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        lock_screen.assert_not_called()
        self.append_activity.assert_called_once()
        event = self.append_activity.call_args
        self.assertEqual(event.args[:4], (
            "owner_verified",
            "已确认本人",
            "最终照片确认本人，已取消锁屏",
            "success",
        ))
        self.assertEqual(event.args[4], {"reason": "stranger", "score": 0.91})
        self.assertEqual(event.kwargs["path"], self.activity_path)

    def test_pause_during_final_evidence_preserves_state_and_lock_cooldown(self) -> None:
        agent = self.make_agent(
            capture_camera_on_lock=True,
            capture_screen_on_lock=False,
            allow_owner_from_final_evidence=True,
        )
        evidence_path = Path(self.temporary_directory.name) / "owner.jpg"
        previous_last_lock_at = agent.last_lock_at

        def pause_then_match(*_args: object) -> tuple[bool, float]:
            write_control(False, self.control_path)
            agent.refresh_control_state()
            return True, 0.91

        with (
            patch("agent.capture_camera_evidence", return_value=evidence_path),
            patch("agent.evidence_matches_owner", side_effect=pause_then_match),
            patch("agent.lock_screen") as lock_screen,
            patch("agent.logging.warning"),
        ):
            agent.lock("stranger")

        lock_screen.assert_not_called()
        self.assertFalse(agent.protection_enabled)
        self.assertEqual(self.write_state.call_args.args[0]["status"], "paused")
        self.assertEqual(agent.last_lock_at, previous_last_lock_at)
        self.assertFalse(
            any(
                call.args[0] == "owner_verified"
                for call in self.append_activity.call_args_list
            )
        )


if __name__ == "__main__":
    unittest.main()
