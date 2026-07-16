#!/usr/bin/env python3
"""Behavior tests for transactional LaunchAgent migration and uninstall."""

from __future__ import annotations

import os
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
AGENT_LABEL = "com.wuyi.mac-face-lock-agent"
UI_LABEL = "com.wuyi.mac-face-lock-status"


class LaunchAgentFixture:
    def __init__(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary_directory.name).resolve() / "home"
        self.root = self.home / "project"
        self.bin = self.root / ".test-bin"
        self.state = self.root / ".test-state"
        self.log = self.root / "calls.log"
        for path in (
            self.bin,
            self.state,
            self.root / "scripts",
            self.root / "launchd",
            self.root / "data" / "evidence",
            self.root / "logs",
            self.root / ".venv" / "bin",
            self.root / "dist" / "Mac Face Lock.app" / "Contents" / "MacOS",
            self.root / "dist" / "Mac Face Lock.app" / "Contents",
            self.root / "dist" / "Mac Face Lock Agent.app" / "Contents" / "MacOS",
            self.root / "dist" / "Mac Face Lock Status.app",
            self.home / "Library" / "LaunchAgents",
        ):
            path.mkdir(parents=True, exist_ok=True)

        shutil.copy2(
            PROJECT_DIR / "scripts" / "install-launchagent.sh",
            self.root / "scripts" / "install-launchagent.sh",
        )
        shutil.copy2(
            PROJECT_DIR / "scripts" / "uninstall-launchagent.sh",
            self.root / "scripts" / "uninstall-launchagent.sh",
        )
        shutil.copy2(
            PROJECT_DIR / "scripts" / "render-launchagents.py",
            self.root / "scripts" / "render-launchagents.py",
        )
        self._write_executable(
            self.root / ".venv" / "bin" / "python",
            f"#!/bin/sh\nexec {shlex.quote(sys.executable)} \"$@\"\n",
        )
        self._write_executable(
            self.root / "dist" / "Mac Face Lock.app" / "Contents" / "MacOS" / "MacFaceLock",
            "#!/bin/sh\n",
        )
        self._write_executable(
            self.root / "dist" / "Mac Face Lock Agent.app" / "Contents" / "MacOS" / "MacFaceLockAgent",
            "#!/bin/sh\n",
        )
        (self.root / "dist" / "Mac Face Lock.app" / "Contents" / "Info.plist").write_text(
            "plist", encoding="utf-8"
        )
        (self.root / "data" / "owner_face.npy").write_bytes(b"owner")
        (self.root / "dist" / "Mac Face Lock Status.app" / "old").write_text(
            "keep until stable", encoding="utf-8"
        )
        self.agent_program = str(
            self.root
            / "dist"
            / "Mac Face Lock Agent.app"
            / "Contents"
            / "MacOS"
            / "MacFaceLockAgent"
        )
        self.ui_program = str(
            self.root
            / "dist"
            / "Mac Face Lock.app"
            / "Contents"
            / "MacOS"
            / "MacFaceLock"
        )
        self.old_agent_program = str(self.root / "old-agent")
        self.old_ui_program = str(self.root / "old-ui")
        self._write_plist(self.root / "launchd" / f"{AGENT_LABEL}.plist", AGENT_LABEL, self.agent_program)
        self._write_plist(self.root / "launchd" / f"{UI_LABEL}.plist", UI_LABEL, self.ui_program)
        self.agent_dst = self.home / "Library" / "LaunchAgents" / f"{AGENT_LABEL}.plist"
        self.ui_dst = self.home / "Library" / "LaunchAgents" / f"{UI_LABEL}.plist"
        self._write_plist(self.agent_dst, AGENT_LABEL, self.old_agent_program)
        self._write_plist(self.ui_dst, UI_LABEL, self.old_ui_program)
        (self.state / f"{AGENT_LABEL}.program").write_text(self.old_agent_program)
        (self.state / f"{UI_LABEL}.program").write_text(self.old_ui_program)
        (self.state / f"{AGENT_LABEL}.loaded").touch()
        (self.state / f"{UI_LABEL}.loaded").touch()
        self._write_executable(
            self.root / "scripts" / "build-app.sh",
            f"#!/bin/sh\necho build-agent >> {self.log!s}\n",
        )
        self._write_executable(
            self.root / "scripts" / "build-status-app.sh",
            f"#!/bin/sh\necho build-ui >> {self.log!s}\n",
        )
        self._write_executable(self.bin / "codesign", "#!/bin/sh\nexit 0\n")
        self._write_executable(self.bin / "plutil", "#!/bin/sh\nexit 0\n")
        self._write_executable(self.bin / "sleep", "#!/bin/sh\nexit 0\n")
        self._write_executable(
            self.bin / "rm",
            f"#!/bin/bash\necho \"rm $*\" >> {self.log!s}\nexec /bin/rm \"$@\"\n",
        )
        shutil.copy2(PROJECT_DIR / "tests" / "fixtures" / "fake-launchctl.sh", self.bin / "launchctl")
        (self.bin / "launchctl").chmod(0o755)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def close(self) -> None:
        self.temporary_directory.cleanup()

    def _write_executable(self, path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _write_plist(self, path: Path, label: str, program: str) -> None:
        with path.open("wb") as handle:
            plistlib.dump(
                {
                    "Label": label,
                    "ProgramArguments": [program, str(self.root)],
                    "RunAtLoad": True,
                    "KeepAlive": True,
                },
                handle,
            )

    def environment(self, **updates: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.bin}:{environment['PATH']}",
                "MAC_FACE_LOCK_TEST_MODE": "1",
                "FAKE_LAUNCHCTL_STATE": str(self.state),
                "FAKE_LAUNCHCTL_LOG": str(self.log),
            }
        )
        environment.update(updates)
        return environment

    def install(self, **updates: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.root / "scripts" / "install-launchagent.sh")],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=self.environment(**updates),
        )

    def install_replacing_build_scripts(self, *, status_exit: int = 0) -> None:
        agent_app = self.root / "dist" / "Mac Face Lock Agent.app"
        unified_app = self.root / "dist" / "Mac Face Lock.app"
        self._write_executable(
            self.root / "scripts" / "build-app.sh",
            "#!/bin/bash\n"
            "set -e\n"
            f"rm -rf {shlex.quote(str(agent_app))}\n"
            f"mkdir -p {shlex.quote(str(agent_app / 'Contents' / 'MacOS'))}\n"
            f"printf '#!/bin/sh\\n' > {shlex.quote(str(agent_app / 'Contents' / 'MacOS' / 'MacFaceLockAgent'))}\n"
            f"chmod +x {shlex.quote(str(agent_app / 'Contents' / 'MacOS' / 'MacFaceLockAgent'))}\n"
            f"printf 'new agent bundle\\n' > {shlex.quote(str(agent_app / 'new-build-sentinel'))}\n"
            f"echo build-agent-replaced >> {shlex.quote(str(self.log))}\n",
        )
        self._write_executable(
            self.root / "scripts" / "build-status-app.sh",
            "#!/bin/bash\n"
            "set -e\n"
            f"rm -rf {shlex.quote(str(unified_app))}\n"
            f"mkdir -p {shlex.quote(str(unified_app / 'Contents' / 'MacOS'))}\n"
            f"printf '#!/bin/sh\\n' > {shlex.quote(str(unified_app / 'Contents' / 'MacOS' / 'MacFaceLock'))}\n"
            f"chmod +x {shlex.quote(str(unified_app / 'Contents' / 'MacOS' / 'MacFaceLock'))}\n"
            f"printf 'plist\\n' > {shlex.quote(str(unified_app / 'Contents' / 'Info.plist'))}\n"
            f"printf 'new unified bundle\\n' > {shlex.quote(str(unified_app / 'new-build-sentinel'))}\n"
            f"echo build-ui-replaced >> {shlex.quote(str(self.log))}\n"
            f"exit {status_exit}\n",
        )


class LaunchAgentScriptTests(unittest.TestCase):
    def test_worktree_guard_makes_zero_launchctl_calls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory).resolve()
            fake_bin = sandbox / "bin"
            fake_root = sandbox / "worktree-project"
            external_root = sandbox / "external-repository"
            fake_bin.mkdir()
            (fake_root / "scripts").mkdir(parents=True)
            external_root.mkdir()
            git_dir = sandbox / "common" / ".git" / "worktrees" / "worktree-project"
            git_common = sandbox / "common" / ".git"
            external_git = external_root / ".git"
            git_dir.mkdir(parents=True)
            external_git.mkdir()
            shutil.copy2(
                PROJECT_DIR / "scripts" / "install-launchagent.sh",
                fake_root / "scripts" / "install-launchagent.sh",
            )
            call_log = fake_bin / "calls.log"
            launchctl = fake_bin / "launchctl"
            launchctl.write_text(
                f"#!/bin/sh\necho called >> {call_log!s}\nexit 0\n", encoding="utf-8"
            )
            launchctl.chmod(0o755)
            git = fake_bin / "git"
            git.write_text(
                "#!/bin/sh\n"
                f"if [ \"$PWD\" = {shlex.quote(str(fake_root))} ]; then\n"
                f"  git_dir={shlex.quote(str(git_dir))}\n"
                f"  git_common={shlex.quote(str(git_common))}\n"
                "else\n"
                f"  git_dir={shlex.quote(str(external_git))}\n"
                f"  git_common={shlex.quote(str(external_git))}\n"
                "fi\n"
                "if [ \"$2\" = \"--git-dir\" ]; then\n"
                "  printf '%s\\n' \"$git_dir\"\n"
                "elif [ \"$2\" = \"--git-common-dir\" ]; then\n"
                "  printf '%s\\n' \"$git_common\"\n"
                "else\n"
                "  exit 1\n"
                "fi\n",
                encoding="utf-8",
            )
            git.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"

            result = subprocess.run(
                [str(fake_root / "scripts" / "install-launchagent.sh")],
                cwd=external_root,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("主仓库目录", result.stderr)
            self.assertFalse(call_log.exists())

    def test_ui_not_running_rolls_back_both_jobs_and_retains_old_app(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)
        old_agent_plist = fixture.agent_dst.read_bytes()
        old_ui_plist = fixture.ui_dst.read_bytes()

        result = fixture.install(FAKE_UI_MODE="crash")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(fixture.agent_dst.read_bytes(), old_agent_plist)
        self.assertEqual(fixture.ui_dst.read_bytes(), old_ui_plist)
        self.assertTrue((fixture.root / "dist" / "Mac Face Lock Status.app").is_dir())
        self.assertEqual(
            (fixture.state / f"{AGENT_LABEL}.program").read_text().strip(),
            fixture.old_agent_program,
        )
        self.assertEqual(
            (fixture.state / f"{UI_LABEL}.program").read_text().strip(),
            fixture.old_ui_program,
        )

    def test_service_validation_failure_restores_bundles_replaced_by_builds(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)
        agent_app = fixture.root / "dist" / "Mac Face Lock Agent.app"
        unified_app = fixture.root / "dist" / "Mac Face Lock.app"
        legacy_app = fixture.root / "dist" / "Mac Face Lock Status.app"
        for bundle, sentinel in (
            (agent_app, "old-agent-bundle"),
            (unified_app, "old-unified-bundle"),
            (legacy_app, "old-legacy-bundle"),
        ):
            (bundle / sentinel).write_text("old\n", encoding="utf-8")
        fixture.install_replacing_build_scripts()

        result = fixture.install(FAKE_UI_MODE="crash")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build-agent-replaced", fixture.log.read_text(encoding="utf-8"))
        self.assertIn("build-ui-replaced", fixture.log.read_text(encoding="utf-8"))
        self.assertTrue((agent_app / "old-agent-bundle").is_file())
        self.assertTrue((unified_app / "old-unified-bundle").is_file())
        self.assertTrue((legacy_app / "old-legacy-bundle").is_file())
        self.assertFalse((agent_app / "new-build-sentinel").exists())
        self.assertFalse((unified_app / "new-build-sentinel").exists())
        self.assertEqual(
            (fixture.state / f"{AGENT_LABEL}.program").read_text().strip(),
            fixture.old_agent_program,
        )
        self.assertEqual(
            (fixture.state / f"{UI_LABEL}.program").read_text().strip(),
            fixture.old_ui_program,
        )

    def test_build_failure_restores_all_preexisting_bundles(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)
        agent_app = fixture.root / "dist" / "Mac Face Lock Agent.app"
        unified_app = fixture.root / "dist" / "Mac Face Lock.app"
        legacy_app = fixture.root / "dist" / "Mac Face Lock Status.app"
        for bundle, sentinel in (
            (agent_app, "old-agent-bundle"),
            (unified_app, "old-unified-bundle"),
            (legacy_app, "old-legacy-bundle"),
        ):
            (bundle / sentinel).write_text("old\n", encoding="utf-8")
        fixture.install_replacing_build_scripts(status_exit=19)

        result = fixture.install()

        self.assertEqual(result.returncode, 19)
        self.assertTrue((agent_app / "old-agent-bundle").is_file())
        self.assertTrue((unified_app / "old-unified-bundle").is_file())
        self.assertTrue((legacy_app / "old-legacy-bundle").is_file())
        self.assertFalse((agent_app / "new-build-sentinel").exists())
        self.assertFalse((unified_app / "new-build-sentinel").exists())
        self.assertEqual(
            (fixture.state / f"{AGENT_LABEL}.program").read_text().strip(),
            fixture.old_agent_program,
        )
        self.assertEqual(
            (fixture.state / f"{UI_LABEL}.program").read_text().strip(),
            fixture.old_ui_program,
        )

    def test_agent_reload_failure_aborts_before_ui_and_rolls_back(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)
        old_agent_plist = fixture.agent_dst.read_bytes()
        old_ui_plist = fixture.ui_dst.read_bytes()

        result = fixture.install(FAKE_AGENT_MODE="fail_load")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(fixture.agent_dst.read_bytes(), old_agent_plist)
        self.assertEqual(fixture.ui_dst.read_bytes(), old_ui_plist)
        self.assertTrue((fixture.root / "dist" / "Mac Face Lock Status.app").is_dir())
        calls = fixture.log.read_text(encoding="utf-8")
        new_ui_bootstrap = f"bootstrap {fixture.ui_dst} {fixture.ui_program}"
        self.assertNotIn(new_ui_bootstrap, calls)

    def test_ui_pid_change_is_rejected_and_old_app_is_retained(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)
        old_ui_plist = fixture.ui_dst.read_bytes()

        result = fixture.install(FAKE_UI_MODE="pid_change")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(fixture.ui_dst.read_bytes(), old_ui_plist)
        self.assertTrue((fixture.root / "dist" / "Mac Face Lock Status.app").is_dir())

    def test_wrong_ui_program_is_rejected_and_old_app_is_retained(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)
        old_ui_plist = fixture.ui_dst.read_bytes()

        result = fixture.install(FAKE_UI_MODE="wrong_program")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(fixture.ui_dst.read_bytes(), old_ui_plist)
        self.assertTrue((fixture.root / "dist" / "Mac Face Lock Status.app").is_dir())

    def test_stable_success_removes_old_app_after_bounded_ui_checks(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)

        result = fixture.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((fixture.root / "dist" / "Mac Face Lock Status.app").exists())
        self.assertEqual(
            (fixture.state / f"{AGENT_LABEL}.program").read_text().strip(), fixture.agent_program
        )
        self.assertEqual(
            (fixture.state / f"{UI_LABEL}.program").read_text().strip(), fixture.ui_program
        )
        calls = fixture.log.read_text(encoding="utf-8").splitlines()
        ui_prints = [
            index
            for index, call in enumerate(calls)
            if call == f"print {UI_LABEL}"
        ]
        old_remove = next(
            index
            for index, call in enumerate(calls)
            if call == f"rm -rf {fixture.root / 'dist' / 'Mac Face Lock Status.app'}"
        )
        self.assertGreaterEqual(len(ui_prints), 4)
        self.assertLess(ui_prints[-1], old_remove)

    def test_uninstall_removes_only_plists_and_preserves_arbitrary_data_tree(self) -> None:
        fixture = LaunchAgentFixture()
        self.addCleanup(fixture.close)
        protected = {
            fixture.root / "data" / "control.json": b"control",
            fixture.root / "data" / "activity.jsonl": b"activity\n",
            fixture.root / "data" / "ui-preferences.json": b"preferences",
            fixture.root / "data" / "owner_face.npy": b"owner",
            fixture.root / "data" / "evidence" / "capture.jpg": b"image",
            fixture.root / "data" / "future-contract.bin": b"future",
        }
        for path, content in protected.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

        result = subprocess.run(
            [str(fixture.root / "scripts" / "uninstall-launchagent.sh")],
            cwd=fixture.root,
            capture_output=True,
            text=True,
            env=fixture.environment(),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(fixture.agent_dst.exists())
        self.assertFalse(fixture.ui_dst.exists())
        self.assertEqual({path: path.read_bytes() for path in protected}, protected)


if __name__ == "__main__":
    unittest.main()
