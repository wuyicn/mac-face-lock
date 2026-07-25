#!/usr/bin/env python3
"""Regression tests for the unified UI package and safe launch migration."""

from __future__ import annotations

import hashlib
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
UNIFIED_APP = PROJECT_DIR / "dist" / "Mac Face Lock.app"
INSTALL_SCRIPT = PROJECT_DIR / "scripts" / "install-launchagent.sh"
AGENT_BUILD_SCRIPT = PROJECT_DIR / "scripts" / "build-app.sh"
AGENT_APP = PROJECT_DIR / "dist" / "Mac Face Lock Agent.app"
UI_BUILD_SCRIPT = PROJECT_DIR / "scripts" / "build-status-app.sh"
APP_ICON_SLOTS = {
    "icon_16x16.png": (16, 16),
    "icon_16x16@2x.png": (32, 32),
    "icon_32x32.png": (32, 32),
    "icon_32x32@2x.png": (64, 64),
    "icon_128x128.png": (128, 128),
    "icon_128x128@2x.png": (256, 256),
    "icon_256x256.png": (256, 256),
    "icon_256x256@2x.png": (512, 512),
    "icon_512x512.png": (512, 512),
    "icon_512x512@2x.png": (1024, 1024),
}


def png_rgba_pixel_digest(path: Path) -> tuple[tuple[int, int], str]:
    """Return dimensions and a digest of decoded RGBA pixels, not PNG metadata."""
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n"), f"not a PNG: {path}"
    offset = 8
    width = height = None
    chunks: list[bytes] = []
    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", payload)
            )
            assert (bit_depth, color_type, compression, filtering, interlace) == (
                8,
                6,
                0,
                0,
                0,
            ), f"expected non-interlaced RGBA PNG: {path}"
        elif kind == b"IDAT":
            chunks.append(payload)
        elif kind == b"IEND":
            break

    assert width is not None and height is not None, f"missing PNG header: {path}"
    stride = width * 4
    filtered = zlib.decompress(b"".join(chunks))
    assert len(filtered) == height * (stride + 1), f"unexpected PNG payload: {path}"
    pixels = bytearray()
    previous = bytearray(stride)
    position = 0
    for _ in range(height):
        filter_type = filtered[position]
        position += 1
        source = filtered[position : position + stride]
        position += stride
        current = bytearray(stride)
        for index, value in enumerate(source):
            left = current[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 0:
                decoded = value
            elif filter_type == 1:
                decoded = value + left
            elif filter_type == 2:
                decoded = value + above
            elif filter_type == 3:
                decoded = value + ((left + above) // 2)
            elif filter_type == 4:
                p = left + above - upper_left
                distances = (abs(p - left), abs(p - above), abs(p - upper_left))
                decoded = value + (left, above, upper_left)[distances.index(min(distances))]
            else:
                raise AssertionError(f"unsupported PNG filter {filter_type}: {path}")
            current[index] = decoded & 0xFF
        pixels.extend(current)
        previous = current
    return (width, height), hashlib.sha256(pixels).hexdigest()


class UnifiedPackagingTests(unittest.TestCase):
    def test_release_signing_keeps_runtime_on_the_unified_tcc_identity(self) -> None:
        runtime_builder = (PROJECT_DIR / "scripts" / "build-runtime.sh").read_text()
        ui_builder = UI_BUILD_SCRIPT.read_text()
        release_builder = (PROJECT_DIR / "scripts" / "build-release.sh").read_text()

        for script in (runtime_builder, ui_builder, release_builder):
            with self.subTest(script=script[:40]):
                self.assertIn(
                    'TCC_SIGNING_REQUIREMENT=\'designated => identifier "com.wuyi.mac-face-lock.app"\'',
                    script,
                )
                self.assertIn('-i "$TCC_BUNDLE_IDENTIFIER"', script)
                self.assertIn('-r="$TCC_SIGNING_REQUIREMENT"', script)

    def test_release_launchagent_targets_the_unified_runtime_dispatcher(self) -> None:
        plist_path = (
            PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-release.plist"
        )
        with plist_path.open("rb") as handle:
            launch = plistlib.load(handle)

        self.assertEqual(launch["Label"], "com.wuyi.mac-face-lock-background")
        self.assertEqual(launch["ProcessType"], "Background")
        self.assertEqual(
            launch["ProgramArguments"],
            [
                "__APP_URL__/Contents/MacOS/MacFaceLock",
                "--internal-runtime",
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

    def test_unified_builder_excludes_agent_and_copies_release_service_template(self) -> None:
        script = UI_BUILD_SCRIPT.read_text()

        self.assertNotIn("Mac Face Lock Agent.app", script)
        self.assertNotIn("MacFaceLockAgent", script)
        self.assertNotIn("scripts/build-app.sh", script)
        self.assertIn(
            'Contents/Resources/runtime/MacFaceLockRuntime/MacFaceLockRuntime',
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

    def test_control_center_runs_as_an_activatable_desktop_application(self) -> None:
        info_path = PROJECT_DIR / "src" / "app" / "Info.plist"
        delegate_path = PROJECT_DIR / "src" / "app" / "AppDelegate.swift"
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)

        self.assertIs(info["LSUIElement"], False)
        delegate = delegate_path.read_text(encoding="utf-8")
        self.assertIn("NSApp.setActivationPolicy(.regular)", delegate)
        self.assertNotIn("NSApp.setActivationPolicy(.accessory)", delegate)

    def test_all_application_termination_routes_use_safe_gate(self) -> None:
        delegate = (PROJECT_DIR / "src/app" / "AppDelegate.swift").read_text()
        quit_coordinator = (
            PROJECT_DIR / "src/app" / "ApplicationQuitCoordinator.swift"
        ).read_text()
        status_menu = (
            PROJECT_DIR / "src/app" / "StatusMenuController.swift"
        ).read_text()

        self.assertIn("func applicationShouldTerminate(", delegate)
        self.assertIn(
            "applicationQuitCoordinator.applicationShouldTerminate",
            delegate,
        )
        self.assertIn("NSApp.reply(toApplicationShouldTerminate: true)", delegate)
        self.assertIn("NSApp.reply(toApplicationShouldTerminate: false)", delegate)
        self.assertIn("退出 Mac Face Lock 并停止保护？", delegate)
        self.assertIn("ApplicationTerminationDecision", quit_coordinator)
        self.assertIn(".terminateLater", quit_coordinator)
        self.assertIn(".terminateCancel", quit_coordinator)
        self.assertIn(".terminateNow", quit_coordinator)
        self.assertIn("requestApplicationTermination", status_menu)
        self.assertNotIn("applicationQuitCoordinator.requestQuit()", status_menu)

    def test_runtime_start_controls_disable_during_application_quit(self) -> None:
        onboarding = (PROJECT_DIR / "src/app" / "OnboardingView.swift").read_text()
        settings = (PROJECT_DIR / "src/app" / "SettingsView.swift").read_text()

        self.assertIn(
            ".disabled(isEnrollmentWorking || setupCoordinator.isQuitting)",
            onboarding,
        )
        self.assertIn(
            ".disabled(isWorking || setupCoordinator.isQuitting)",
            onboarding,
        )
        self.assertIn(
            ".disabled(isEnrollmentWorking || setupCoordinator.isQuitting)",
            settings,
        )

    def test_control_center_packages_the_project_owned_icon(self) -> None:
        info_path = PROJECT_DIR / "src" / "app" / "Info.plist"
        icon_path = PROJECT_DIR / "src" / "app" / "AppIcon.icns"
        builder = UI_BUILD_SCRIPT.read_text(encoding="utf-8")
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleIconFile"], "AppIcon")
        self.assertTrue(icon_path.is_file())
        self.assertGreater(icon_path.stat().st_size, 10_000)
        self.assertIn(
            'cp "$ROOT_DIR/src/app/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"',
            builder,
        )

        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(
                [
                    "iconutil",
                    "-c",
                    "iconset",
                    "-o",
                    str(Path(directory) / "AppIcon.iconset"),
                    str(icon_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

    def test_app_icon_regeneration_uses_fixed_pixels_and_matches_asset(self) -> None:
        renderer = PROJECT_DIR / "scripts" / "generate-app-icon.swift"
        generator = PROJECT_DIR / "scripts" / "generate-app-icon.sh"
        committed = PROJECT_DIR / "src" / "app" / "AppIcon.icns"

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            master = temporary / "AppIcon-1024.png"
            regenerated = temporary / "AppIcon.icns"
            subprocess.run(
                ["xcrun", "swift", str(renderer), str(master)],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(png_rgba_pixel_digest(master)[0], (1024, 1024))

            subprocess.run(
                [str(generator), str(regenerated)],
                check=True,
                capture_output=True,
                text=True,
            )

            extracted_digests: dict[str, dict[str, str]] = {}
            for label, icon in (("committed", committed), ("regenerated", regenerated)):
                iconset = temporary / f"{label}.iconset"
                subprocess.run(
                    ["iconutil", "-c", "iconset", "-o", str(iconset), str(icon)],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    {image.name for image in iconset.iterdir()},
                    set(APP_ICON_SLOTS),
                )
                extracted_digests[label] = {}
                for name, dimensions in APP_ICON_SLOTS.items():
                    actual_dimensions, digest = png_rgba_pixel_digest(iconset / name)
                    self.assertEqual(actual_dimensions, dimensions, name)
                    extracted_digests[label][name] = digest

            # iconutil output bytes may vary with container metadata; decoded
            # pixels must remain identical for each declared icon representation.
            self.assertEqual(
                extracted_digests["regenerated"],
                extracted_digests["committed"],
            )

    def test_interactive_cards_use_non_hit_testing_decorative_borders(self) -> None:
        border_path = PROJECT_DIR / "src" / "app" / "DecorativeCardBorder.swift"
        self.assertTrue(border_path.is_file())
        border = border_path.read_text(encoding="utf-8")
        onboarding = (
            PROJECT_DIR / "src" / "app" / "OnboardingView.swift"
        ).read_text(encoding="utf-8")
        settings = (
            PROJECT_DIR / "src" / "app" / "SettingsView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn(".allowsHitTesting(false)", border)
        self.assertIn("DecorativeCardBorder(", onboarding)
        self.assertIn("DecorativeCardBorder(", settings)

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
        status_menu = (
            PROJECT_DIR / "src/app" / "StatusMenuController.swift"
        ).read_text()
        setup_coordinator = (
            PROJECT_DIR / "src/app" / "SetupCoordinator.swift"
        ).read_text()
        views = (PROJECT_DIR / "src/app" / "Views.swift").read_text()

        for label in (
            "准备检查",
            "权限中心",
            "录入本人",
            "权限确认",
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
            "修复后台保护",
            "查看日志",
        ):
            with self.subTest(settings_label=label):
                self.assertIn(label, settings)

        self.assertIn("setupCoordinator.hasCompletedOnboarding", views)
        self.assertIn("setupCoordinator.isLiveReady", views)
        self.assertIn("RootDestination.resolve", views)
        self.assertIn("OnboardingView(", views)
        for permission_title in (
            "Mac Face Lock 摄像头",
            "Mac Face Lock 输入监控",
            "Mac Face Lock 辅助功能",
        ):
            with self.subTest(permission_title=permission_title):
                self.assertIn(permission_title, onboarding)
                self.assertIn(permission_title, settings)
        self.assertIn("退出 Mac Face Lock 并停止保护", status_menu)
        self.assertIn("enrollmentLifecycle", onboarding)

        for guidance in (
            "EnrollmentPoseGuide",
            "正脸 · 左转约 30° · 右转约 30° · 轻微抬头 · 轻微低头",
            "正对摄像头，脸部保持居中",
            "只转动头部约 30°，身体保持不动",
            "轻抬下巴约 15–20°，不要后仰身体",
            "轻收下巴约 15–20°，不要弯腰或把脸完全低下去",
        ):
            with self.subTest(enrollment_guidance=guidance):
                self.assertIn(guidance, onboarding)

        user_facing_sources = (
            onboarding + settings + status_menu + setup_coordinator + views
        )
        for retired_copy in (
            "Agent 权限",
            "Agent 状态",
            "后台 Agent",
            "重新安装 Agent",
            "退出界面",
        ):
            with self.subTest(retired_copy=retired_copy):
                self.assertNotIn(retired_copy, user_facing_sources)

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

    def test_permission_confirmation_uses_live_status_without_security_test_action(
        self,
    ) -> None:
        onboarding = (PROJECT_DIR / "src/app/OnboardingView.swift").read_text()
        settings = (PROJECT_DIR / "src/app/SettingsView.swift").read_text()

        step_start = onboarding.index("    private var permissionStatusStep")
        step_end = onboarding.index(
            "    private var completionStep",
            step_start,
        )
        permission_step = onboarding[step_start:step_end]

        for token in (
            'title: "权限确认"',
            'readinessRow(.ownerProfile, title: "本人人脸资料")',
            'readinessRow(.serviceHealth, title: "后台服务")',
            'agentPermissionRow(.camera, title: "Mac Face Lock 摄像头")',
            'agentPermissionRow(.inputMonitoring, title: "Mac Face Lock 输入监控")',
            'agentPermissionRow(.accessibility, title: "Mac Face Lock 辅助功能")',
            'Button("确认权限并继续")',
            "await setupCoordinator.completePermissionStatusStep()",
        ):
            with self.subTest(permission_status_token=token):
                self.assertIn(token, permission_step)

        self.assertEqual(permission_step.count("agentPermissionRow("), 3)
        for retired_token in (
            ".diagnosis",
            ".ownerTest",
            "runSafetyTest",
            "安全测试",
        ):
            with self.subTest(retired_permission_status_token=retired_token):
                self.assertNotIn(retired_token, permission_step)

        for retired_copy in (
            'Button("运行安全测试")',
            'Button("重新运行安全测试")',
            "请重新完成安全测试",
            "请重新运行安全测试",
        ):
            with self.subTest(retired_security_test_action=retired_copy):
                self.assertNotIn(retired_copy, onboarding + settings)

        self.assertIn('Button("刷新权限与运行状态")', settings)
        self.assertIn("await setupCoordinator.refreshLiveReadiness()", settings)

    def test_onboarding_action_feedback_resets_only_on_real_step_changes(
        self,
    ) -> None:
        onboarding = (
            PROJECT_DIR / "src/app/OnboardingView.swift"
        ).read_text(encoding="utf-8")
        lifecycle_start = onboarding.index("        .onAppear {")
        lifecycle_end = onboarding.index(
            "        .confirmationDialog(",
            lifecycle_start,
        )
        lifecycle = onboarding[lifecycle_start:lifecycle_end]

        self.assertIn(
            "updatePermissionPolling(for: setupCoordinator.currentStep)",
            lifecycle,
        )
        self.assertNotIn(
            ".onReceive(setupCoordinator.$currentStep",
            lifecycle,
        )
        change_start = lifecycle.index(
            ".onChange(of: setupCoordinator.currentStep) { newStep in"
        )
        change = lifecycle[change_start:]
        self.assertEqual(change.count("actionState = .idle"), 1)
        self.assertIn("updatePermissionPolling(for: newStep)", change)

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
