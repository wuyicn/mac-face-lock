#!/usr/bin/env python3
"""Regression tests for the unified UI package and safe launch migration."""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
UNIFIED_APP = PROJECT_DIR / "dist" / "Mac Face Lock.app"
INSTALL_SCRIPT = PROJECT_DIR / "scripts" / "install-launchagent.sh"
AGENT_BUILD_SCRIPT = PROJECT_DIR / "scripts" / "build-app.sh"
AGENT_APP = PROJECT_DIR / "dist" / "Mac Face Lock Agent.app"
UI_BUILD_SCRIPT = PROJECT_DIR / "scripts" / "build-status-app.sh"


class UnifiedPackagingTests(unittest.TestCase):
    def test_release_launchagent_targets_only_embedded_agent_and_support_paths(
        self,
    ) -> None:
        plist_path = (
            PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-release.plist"
        )
        with plist_path.open("rb") as handle:
            launch = plistlib.load(handle)

        self.assertEqual(launch["Label"], "com.wuyi.mac-face-lock-agent")
        self.assertEqual(
            launch["ProgramArguments"],
            [
                "__APP_URL__/Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent",
                "--resources-dir",
                "__APP_URL__/Contents/Resources",
                "--support-dir",
                "__SUPPORT_URL__",
                "agent",
            ],
        )
        rendered = plist_path.read_text(encoding="utf-8")
        self.assertNotIn(".venv", rendered)
        self.assertNotIn("__PROJECT_DIR__", rendered)

    def test_unified_builder_embeds_agent_and_release_service_template(self) -> None:
        script = UI_BUILD_SCRIPT.read_text()

        self.assertIn(
            'Contents/Library/LoginItems/Mac Face Lock Agent.app',
            script,
        )
        self.assertIn("com.wuyi.mac-face-lock-release.plist", script)

    def test_bundle_metadata_names_the_unified_application(self) -> None:
        info_path = PROJECT_DIR / "src" / "app" / "Info.plist"
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleName"], "Mac Face Lock")
        self.assertEqual(info["CFBundleDisplayName"], "Mac Face Lock")
        self.assertEqual(info["CFBundleIdentifier"], "com.wuyi.mac-face-lock.app")
        self.assertEqual(info["CFBundleVersion"], "1")
        self.assertEqual(info["CFBundleShortVersionString"], "0.2.0")
        self.assertEqual(info["CFBundleExecutable"], "MacFaceLock")
        self.assertEqual(info["CFBundlePackageType"], "APPL")
        self.assertEqual(info["LSMinimumSystemVersion"], "12.0")
        self.assertIs(info["LSUIElement"], True)

    def test_ui_launchagent_keeps_label_and_targets_only_unified_app(self) -> None:
        plist_path = (
            PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-status.plist"
        )
        with plist_path.open("rb") as handle:
            launch = plistlib.load(handle)

        expected_root = "__PROJECT_DIR__"
        self.assertEqual(launch["Label"], "com.wuyi.mac-face-lock-status")
        self.assertEqual(
            launch["ProgramArguments"],
            [
                f"{expected_root}/dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock",
                expected_root,
            ],
        )
        self.assertNotIn("Mac Face Lock Status.app", plist_path.read_text())

    def test_ui_normal_exit_does_not_loop_while_agent_policy_is_unchanged(self) -> None:
        ui_path = PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-status.plist"
        agent_path = PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-agent.plist"
        with ui_path.open("rb") as handle:
            ui = plistlib.load(handle)
        with agent_path.open("rb") as handle:
            agent = plistlib.load(handle)

        self.assertIs(ui["RunAtLoad"], True)
        self.assertEqual(ui["KeepAlive"], {"SuccessfulExit": False})
        self.assertIs(agent["RunAtLoad"], True)
        self.assertIs(agent["KeepAlive"], True)

    def test_installer_refuses_live_migration_from_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory).resolve()
            fake_root = sandbox / "worktree-project"
            external_root = sandbox / "external-repository"
            fake_bin = sandbox / "bin"
            git_dir = sandbox / "common" / ".git" / "worktrees" / "worktree-project"
            git_common = sandbox / "common" / ".git"
            external_git = external_root / ".git"
            fake_bin.mkdir()
            git_dir.mkdir(parents=True)
            external_git.mkdir(parents=True)
            (fake_root / "scripts").mkdir(parents=True)
            shutil.copy2(
                PROJECT_DIR / "scripts" / "install-launchagent.sh",
                fake_root / "scripts" / "install-launchagent.sh",
            )
            git = fake_bin / "git"
            git.write_text(
                "#!/bin/sh\n"
                f"if [ \"$PWD\" = '{fake_root}' ]; then\n"
                f"  git_dir='{git_dir}'\n"
                f"  git_common='{git_common}'\n"
                "else\n"
                f"  git_dir='{external_git}'\n"
                f"  git_common='{external_git}'\n"
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

    def test_installer_renders_portable_plists_and_checks_linked_worktrees(self) -> None:
        script = INSTALL_SCRIPT.read_text()
        self.assertNotIn("/" + "Users" + "/", script)
        self.assertIn("render-launchagents.py", script)
        self.assertIn("git rev-parse --git-common-dir", script)

    def test_agent_builder_compiles_portable_launcher(self) -> None:
        script = AGENT_BUILD_SCRIPT.read_text()
        self.assertIn("src/agent-launcher/main.swift", script)
        self.assertIn("-parse-as-library", script)
        self.assertNotIn("CommandLineTools/Library/Frameworks/Python3.framework", script)
        self.assertNotIn("install_name_tool", script)

    def test_agent_builder_targets_apple_silicon_macos_12(self) -> None:
        script = AGENT_BUILD_SCRIPT.read_text()
        self.assertIn("-target arm64-apple-macosx12.0", script)

    def test_ui_builder_targets_apple_silicon_macos_12(self) -> None:
        script = UI_BUILD_SCRIPT.read_text()
        self.assertIn("-target arm64-apple-macosx12.0", script)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS build tools")
    def test_built_agent_matches_declared_minimum_system_version(self) -> None:
        subprocess.run(
            [str(AGENT_BUILD_SCRIPT)],
            cwd=PROJECT_DIR,
            check=True,
            capture_output=True,
            text=True,
        )
        info_path = AGENT_APP / "Contents" / "Info.plist"
        executable = AGENT_APP / "Contents" / "MacOS" / "MacFaceLockAgent"
        with info_path.open("rb") as handle:
            declared_minimum = plistlib.load(handle)["LSMinimumSystemVersion"]
        build_info = subprocess.run(
            ["xcrun", "vtool", "-show-build", str(executable)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        match = re.search(r"\bminos\s+([0-9.]+)", build_info)

        self.assertIsNotNone(match, build_info)
        self.assertEqual(match.group(1), declared_minimum)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS build tools")
    def test_built_agent_uses_public_beta_bundle_version(self) -> None:
        subprocess.run(
            [str(AGENT_BUILD_SCRIPT)],
            cwd=PROJECT_DIR,
            check=True,
            capture_output=True,
            text=True,
        )
        with (AGENT_APP / "Contents" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleVersion"], "1")
        self.assertEqual(info["CFBundleShortVersionString"], "0.2.0")

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS build tools")
    def test_built_ui_matches_declared_minimum_system_version(self) -> None:
        build = subprocess.run(
            [str(UI_BUILD_SCRIPT)],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            build.returncode,
            0,
            "UI build failed.\n"
            f"stdout:\n{build.stdout}\n"
            f"stderr:\n{build.stderr}",
        )
        info_path = UNIFIED_APP / "Contents" / "Info.plist"
        executable = UNIFIED_APP / "Contents" / "MacOS" / "MacFaceLock"
        with info_path.open("rb") as handle:
            declared_minimum = plistlib.load(handle)["LSMinimumSystemVersion"]
        build_info = subprocess.run(
            ["xcrun", "vtool", "-show-build", str(executable)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        match = re.search(r"\bminos\s+([0-9.]+)", build_info)

        self.assertIsNotNone(match, build_info)
        self.assertEqual(match.group(1), declared_minimum)

    def test_agent_builder_publishes_verified_staging_bundle_atomically(self) -> None:
        script = AGENT_BUILD_SCRIPT.read_text()
        self.assertIn(".Mac Face Lock Agent.app.building", script)
        self.assertIn("scripts/atomic-swap.py", script)
        self.assertIn('codesign --verify --deep --strict "$BUILD_DIR"', script)
        self.assertNotIn('rm -rf "$APP_DIR"', script)

    def test_agent_launcher_has_no_developer_path(self) -> None:
        source = (PROJECT_DIR / "src/agent-launcher/main.swift").read_text()
        self.assertNotIn("/" + "Users" + "/", source)

    def test_ui_sources_have_no_developer_paths(self) -> None:
        for source in (PROJECT_DIR / "src/app").glob("*.swift"):
            with self.subTest(source=source.name):
                self.assertNotIn("/" + "Users" + "/", source.read_text())

    def test_onboarding_sources_define_complete_customer_flow(self) -> None:
        onboarding = (PROJECT_DIR / "src/app" / "OnboardingView.swift").read_text()
        settings = (PROJECT_DIR / "src/app" / "SettingsView.swift").read_text()
        views = (PROJECT_DIR / "src/app" / "Views.swift").read_text()

        for label in (
            "准备检查",
            "权限中心",
            "录入本人",
            "安全测试",
            "完成并开启",
        ):
            with self.subTest(onboarding_step=label):
                self.assertIn(label, onboarding)

        for label in (
            "权限与运行状态",
            "本人资料",
            "保护规则",
            "服务诊断与修复",
            "外观",
            "重新录入本人",
            "刷新权限",
            "打开系统设置",
            "重新启动服务",
            "重新安装服务",
            "查看日志",
        ):
            with self.subTest(settings_label=label):
                self.assertIn(label, settings)

        self.assertIn("setupCoordinator.hasCompletedOnboarding", views)
        self.assertIn("setupCoordinator.isLiveReady", views)
        self.assertIn("RootDestination.resolve", views)
        self.assertIn("OnboardingView(", views)
        self.assertIn("Mac Face Lock 控制中心权限", onboarding)
        self.assertIn("Mac Face Lock Agent 权限", onboarding)
        self.assertIn("Mac Face Lock 控制中心权限", settings)
        self.assertIn("Mac Face Lock Agent 权限", settings)
        self.assertIn("enrollmentLifecycle", onboarding)

        user_facing_sources = onboarding + settings
        for shell_copy in (
            "launchctl ",
            "python ",
            "python3 ",
            "终端运行",
            "打开终端",
        ):
            with self.subTest(shell_copy=shell_copy):
                self.assertNotIn(shell_copy, user_facing_sources)

        for technical_copy in (
            "launchctl",
            "bash ",
            "scripts/",
            "config/config.json",
            "data/",
            "logs/",
            ".venv",
            "dist/",
            "Library/LaunchAgents",
            "/" + "Users/",
            "~/Library",
        ):
            with self.subTest(onboarding_technical_copy=technical_copy):
                self.assertNotIn(technical_copy, onboarding)

    def test_ui_consumers_do_not_rebuild_the_validated_data_path(self) -> None:
        for relative_path in (
            "src/app/AppDelegate.swift",
            "src/app/DesktopWindowController.swift",
            "src/app/LocalJSONStore.swift",
            "src/app/StatusMenuController.swift",
            "src/app/Views.swift",
        ):
            with self.subTest(path=relative_path):
                source = (PROJECT_DIR / relative_path).read_text()
                self.assertNotIn(
                    'projectURL.appendingPathComponent("data',
                    source,
                )

        local_store_source = (PROJECT_DIR / "src/app/LocalJSONStore.swift").read_text()
        self.assertIn("init(resourcesURL: URL, dataURL: URL)", local_store_source)

    def test_status_names_the_combined_ui(self) -> None:
        status_script = (PROJECT_DIR / "scripts" / "status.sh").read_text()
        self.assertIn("融合界面", status_script)

    def test_superseded_status_source_is_not_in_the_build_graph(self) -> None:
        self.assertFalse(
            (PROJECT_DIR / "src" / "statusbar" / "StatusBarApp.swift").exists()
        )

    def test_shell_scripts_are_syntactically_valid(self) -> None:
        for relative_path in (
            "scripts/build-status-app.sh",
            "scripts/install-launchagent.sh",
            "scripts/uninstall-launchagent.sh",
            "scripts/status.sh",
            "tests/fixtures/fake-launchctl.sh",
        ):
            with self.subTest(path=relative_path):
                subprocess.run(
                    ["bash", "-n", str(PROJECT_DIR / relative_path)],
                    check=True,
                    capture_output=True,
                    text=True,
                )


class AgentBuildFailureRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name) / "project"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "src" / "agent-launcher").mkdir(parents=True)
        (self.root / ".test-bin").mkdir()
        shutil.copy2(AGENT_BUILD_SCRIPT, self.root / "scripts" / "build-app.sh")
        shutil.copy2(
            PROJECT_DIR / "scripts" / "atomic-swap.py",
            self.root / "scripts" / "atomic-swap.py",
        )
        (self.root / "src" / "agent-launcher" / "main.swift").write_text(
            "@main enum Agent { static func main() {} }\n",
            encoding="utf-8",
        )
        self._write_tool(
            "xcrun",
            """#!/bin/bash
set -e
[[ "${FAKE_SWIFTC_FAIL:-0}" != "1" ]] || exit 9
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    shift
    printf '#!/bin/sh\n' > "$1"
    chmod +x "$1"
    exit 0
  fi
  shift
done
exit 2
""",
        )
        self._write_tool(
            "codesign",
            """#!/bin/bash
set -e
target="${@: -1}"
if [[ " $* " == *" --sign "* || " $* " == *" -s "* ]]; then
  [[ "${FAKE_CODESIGN_FAIL_SIGN:-0}" != "1" ]] || exit 9
  touch "$target/.test-signed"
  exit 0
fi
if [[ " $* " == *" --verify "* ]]; then
  [[ -f "$target/.test-signed" ]]
  exit
fi
exit 2
""",
        )
        self._write_tool("plutil", "#!/bin/bash\nexit 0\n")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_tool(self, name: str, body: str) -> None:
        path = self.root / ".test-bin" / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def _run_build(self, **updates: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.root / '.test-bin'}:{environment['PATH']}"
        environment.update(updates)
        return subprocess.run(
            [str(self.root / "scripts" / "build-app.sh")],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=environment,
        )

    def _install_old_bundle(self) -> Path:
        initial = self._run_build()
        self.assertEqual(initial.returncode, 0, initial.stderr)
        app = self.root / "dist" / "Mac Face Lock Agent.app"
        (app / "old-version").write_text("keep", encoding="utf-8")
        return app

    def test_compile_failure_preserves_current_agent_bundle(self) -> None:
        app = self._install_old_bundle()

        failed = self._run_build(FAKE_SWIFTC_FAIL="1")

        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue((app / "old-version").is_file())
        self.assertEqual((app / "old-version").read_text(), "keep")

    def test_signing_failure_preserves_current_agent_bundle(self) -> None:
        app = self._install_old_bundle()

        failed = self._run_build(FAKE_CODESIGN_FAIL_SIGN="1")

        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue((app / "old-version").is_file())
        self.assertEqual((app / "old-version").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
