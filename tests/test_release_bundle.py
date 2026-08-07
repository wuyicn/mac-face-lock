from __future__ import annotations

import hashlib
import inspect
import json
import os
import plistlib
import select
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import numpy as np


PROJECT_DIR = Path(__file__).resolve().parents[1]
BUILD_REQUIREMENTS = PROJECT_DIR / "requirements-build.txt"
BUILD_LOCK = PROJECT_DIR / "requirements-build-lock.txt"
RUNTIME_SPEC = PROJECT_DIR / "packaging" / "mac-face-lock-runtime.spec"
BUILD_RUNTIME = PROJECT_DIR / "scripts" / "build-runtime.sh"
BUILD_RELEASE = PROJECT_DIR / "scripts" / "build-release.sh"
MANIFEST_TOOL = PROJECT_DIR / "scripts" / "release-manifest.py"
MANUAL_ACCEPTANCE = PROJECT_DIR / "scripts" / "manual-release-acceptance.sh"
RELEASE_WORKFLOW = PROJECT_DIR / ".github/workflows/release-artifact.yml"
RELEASE_ROOT = PROJECT_DIR / "dist" / "release"
ZIP_PATH = RELEASE_ROOT / "Mac-Face-Lock-0.2.0-beta-arm64.zip"
CHECKSUM_PATH = ZIP_PATH.with_suffix(ZIP_PATH.suffix + ".sha256")
UV_ACTION_SHA = "08807647e7069bb48b6ef5acd8ec9567f424441b"
UV_VERSION = "0.11.13"
REQUIRED_LICENSES = (
    "Python/LICENSE.txt",
    "NumPy/LICENSE.txt",
    "opencv-python/LICENSE.txt",
    "opencv-python/LICENSE-3RD-PARTY.txt",
    "pynput/COPYING.LGPL",
    "six/LICENSE",
    "PyObjC/LICENSE.txt",
)
FIXTURE_SOURCE_COMMIT = "0123456789abcdef0123456789abcdef01234567"


def find_forbidden_token(path: Path, tokens: tuple[bytes, ...]) -> bytes | None:
    longest = max((len(token) for token in tokens), default=1)
    carry = b""
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            data = carry + chunk
            for token in tokens:
                if token in data:
                    return token
            carry = data[-(longest - 1):] if longest > 1 else b""
    return None


class ReleaseBundlePolicyTests(unittest.TestCase):
    def test_manual_acceptance_checklist_is_executable_and_non_mutating(self) -> None:
        self.assertTrue(MANUAL_ACCEPTANCE.is_file())
        self.assertTrue(os.access(MANUAL_ACCEPTANCE, os.X_OK))
        source = MANUAL_ACCEPTANCE.read_text(encoding="utf-8")
        for forbidden in (
            "dscl",
            "sysadminctl",
            "tccutil",
            "sudo",
            "launchctl",
            "open -a",
            "MacFaceLock\"",
        ):
            self.assertNotIn(forbidden, source)

        result = subprocess.run(
            [str(MANUAL_ACCEPTANCE), "--print-only"],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source_commit", source)
        for token in (
            "新建的普通测试账户",
            "Codex、Python、Xcode",
            "Finder",
            "右键",
            "摄像头",
            "录入本人",
            "权限确认",
            "重新登录",
            "撤销并恢复",
            "卸载后台服务并保留数据",
            "PENDING",
        ):
            self.assertIn(token, result.stdout)

    def test_manual_release_workflow_declares_pinned_uv(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            f"astral-sh/setup-uv@{UV_ACTION_SHA}",
            workflow,
        )
        self.assertIn(f'version: "{UV_VERSION}"', workflow)
        self.assertIn("contents: read", workflow)
        self.assertNotIn("contents: write", workflow)

    def test_build_runtime_fails_cleanly_when_uv_is_not_on_path(self) -> None:
        environment = os.environ.copy()
        environment.pop("UV_BIN", None)
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result = subprocess.run(
            [str(BUILD_RUNTIME)],
            cwd=PROJECT_DIR,
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            f"uv {UV_VERSION} is required",
            result.stderr,
        )

    def test_release_build_uses_ephemeral_cleaned_staging(self) -> None:
        runtime = BUILD_RUNTIME.read_text(encoding="utf-8")
        release = BUILD_RELEASE.read_text(encoding="utf-8")
        self.assertNotIn('STAGED_SOURCE="/tmp/mac-face-lock-runtime-build"', runtime)
        self.assertNotIn('STAGING_DIR="$ROOT_DIR/.build/release-staging"', release)
        self.assertNotIn('EXTRACTED="$ROOT_DIR/.build/release-extracted"', release)
        for script in (runtime, release):
            self.assertIn("mktemp -d", script)
            self.assertIn("trap ", script)

    def test_release_runtime_smoke_test_never_launches_gui_control_center(self) -> None:
        source = inspect.getsource(
            ExtractedReleaseBundleTests
            .test_extracted_release_environment_launches_without_developer_tools
        )
        self.assertIn('"--internal-runtime"', source)
        self.assertIn('"diagnose"', source)
        self.assertNotIn("subprocess.Popen", source)

    def test_path_scan_has_no_file_size_bypass(self) -> None:
        source = inspect.getsource(
            ExtractedReleaseBundleTests
            .test_bundle_contains_no_developer_or_python_dependency_paths
        )
        self.assertNotIn("20_000_000", source)
        with tempfile.TemporaryDirectory() as directory:
            large = Path(directory) / "large.bin"
            with large.open("wb") as handle:
                handle.seek(21 * 1024 * 1024)
                handle.write(b"/usr/bin/python")
            self.assertEqual(
                find_forbidden_token(large, (b"/usr/bin/python",)),
                b"/usr/bin/python",
            )

    def test_build_inputs_pin_python311_and_pyinstaller6210(self) -> None:
        self.assertEqual(
            BUILD_REQUIREMENTS.read_text(encoding="utf-8").strip(),
            "PyInstaller==6.21.0",
        )
        lock = BUILD_LOCK.read_text(encoding="utf-8")
        self.assertIn("pyinstaller==6.21.0", lock.lower())
        self.assertIn("altgraph==", lock)
        self.assertIn("macholib==", lock)
        runtime_script = BUILD_RUNTIME.read_text(encoding="utf-8")
        self.assertIn("3.11", runtime_script)
        self.assertIn("MACOSX_DEPLOYMENT_TARGET=12.0", runtime_script)

    def test_release_build_sources_define_required_offline_contents(self) -> None:
        spec = RUNTIME_SPEC.read_text(encoding="utf-8")
        release = BUILD_RELEASE.read_text(encoding="utf-8")
        for token in (
            "cv2",
            "numpy",
            "PyObjC",
            "haarcascades",
        ):
            self.assertIn(token, spec)
        for token in (
            "defaults/config.json",
            "runtime/MacFaceLockRuntime",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "BuildManifest.json",
            "codesign",
            "ditto",
            "shasum",
        ):
            self.assertIn(token, release)
        for forbidden in (
            "scripts/build-app.sh",
        ):
            self.assertNotIn(forbidden, release)
        for required_absence_check in (
            '[[ -e "$APP/Contents/Library/LoginItems/Mac Face Lock Agent.app" ]]',
            'find "$APP" -name MacFaceLockAgent -print -quit',
            'grep -a -r -q "com.wuyi.mac-face-lock-agent.app" "$APP"',
        ):
            self.assertIn(required_absence_check, release)
        self.assertIn("release-manifest.py", release)
        self.assertIn('"$RESOURCES/licenses"', release)
        self.assertIn("git status --porcelain=v1 --untracked-files=all", release)
        self.assertIn("git rev-parse HEAD", release)
        self.assertIn('"$SOURCE_COMMIT"', release)

    def test_third_party_notices_enumerate_bundled_license_files(self) -> None:
        notices = (PROJECT_DIR / "THIRD_PARTY_NOTICES.md").read_text(
            encoding="utf-8"
        )
        for relative in REQUIRED_LICENSES:
            self.assertIn(f"`licenses/{relative}`", notices)
        for component in (
            "pyobjc-core",
            "pyobjc-framework-ApplicationServices",
            "pyobjc-framework-Cocoa",
            "pyobjc-framework-CoreText",
            "pyobjc-framework-Quartz",
        ):
            self.assertIn(component, notices)


class ReleaseManifestToolTests(unittest.TestCase):
    def run_tool(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(MANIFEST_TOOL), *arguments],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )

    def test_manifest_scope_is_non_cyclic_and_mutation_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Fixture.app"
            payload = app / "Contents/Resources/defaults/config.json"
            signature = app / "Contents/_CodeSignature/CodeResources"
            executable = app / "Contents/MacOS/Fixture"
            payload.parent.mkdir(parents=True)
            signature.parent.mkdir(parents=True)
            executable.parent.mkdir(parents=True)
            payload.write_text('{"ok":true}\n', encoding="utf-8")
            signature.write_text("signature\n", encoding="utf-8")
            executable.write_bytes(bytes.fromhex("cffaedfe") + b"\0" * 64)
            manifest = app / "Contents/Resources/BuildManifest.json"

            generated = self.run_tool(
                "generate",
                str(app),
                str(manifest),
                FIXTURE_SOURCE_COMMIT,
            )
            self.assertEqual(generated.returncode, 0, generated.stderr)
            verified = self.run_tool("verify", str(app), str(manifest))
            self.assertEqual(verified.returncode, 0, verified.stderr)

            document = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(document["schema_version"], 3)
            self.assertEqual(document["source_commit"], FIXTURE_SOURCE_COMMIT)
            self.assertEqual(document["scope"], "final_non_code_payload")
            self.assertEqual(
                {item["reason"] for item in document["excluded_files"]},
                {"manifest_self", "code_signature", "mach_o_code"},
            )
            self.assertEqual(len(document["files"]), 1)

            payload.write_text('{"ok":false}\n', encoding="utf-8")
            mutated = self.run_tool("verify", str(app), str(manifest))
            self.assertNotEqual(mutated.returncode, 0)
            self.assertIn("digest mismatch", mutated.stderr)

    def test_manifest_rejects_invalid_source_commits(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Fixture.app"
            app.mkdir()
            manifest = app / "Contents/Resources/BuildManifest.json"
            invalid_commits = (
                FIXTURE_SOURCE_COMMIT.upper(),
                FIXTURE_SOURCE_COMMIT[:-1],
                "z" * 40,
            )
            for source_commit in invalid_commits:
                with self.subTest(source_commit=source_commit):
                    generated = self.run_tool(
                        "generate",
                        str(app),
                        str(manifest),
                        source_commit,
                    )
                    self.assertNotEqual(generated.returncode, 0)
                    self.assertIn("source commit", generated.stderr)

    def test_manifest_verify_rejects_invalid_recorded_source_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Fixture.app"
            app.mkdir()
            manifest = app / "Contents/Resources/BuildManifest.json"
            generated = self.run_tool(
                "generate",
                str(app),
                str(manifest),
                FIXTURE_SOURCE_COMMIT,
            )
            self.assertEqual(generated.returncode, 0, generated.stderr)
            document = json.loads(manifest.read_text(encoding="utf-8"))
            document["source_commit"] = "not-a-commit"
            manifest.write_text(json.dumps(document), encoding="utf-8")

            verified = self.run_tool("verify", str(app), str(manifest))

            self.assertNotEqual(verified.returncode, 0)
            self.assertIn("source commit", verified.stderr)


class ExtractedReleaseBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        supplied_app = os.environ.get("MAC_FACE_LOCK_RELEASE_APP")
        if supplied_app:
            cls.app = Path(supplied_app)
            cls.temp = None
            return
        if os.environ.get("MAC_FACE_LOCK_REQUIRE_RELEASE_ARTIFACT") != "1":
            raise unittest.SkipTest("release artifact gate not requested")
        subprocess.run([str(BUILD_RELEASE)], cwd=PROJECT_DIR, check=True)
        cls.temp = tempfile.TemporaryDirectory()
        subprocess.run(
            ["ditto", "-x", "-k", str(ZIP_PATH), cls.temp.name],
            check=True,
        )
        cls.app = Path(cls.temp.name) / "Mac Face Lock.app"

    @classmethod
    def tearDownClass(cls) -> None:
        if getattr(cls, "temp", None) is not None:
            cls.temp.cleanup()

    def test_checksum_matches(self) -> None:
        if os.environ.get("MAC_FACE_LOCK_RELEASE_APP"):
            self.skipTest("checksum is validated by build-release.sh")
        expected = CHECKSUM_PATH.read_text(encoding="utf-8").split()[0]
        actual = hashlib.sha256(ZIP_PATH.read_bytes()).hexdigest()
        self.assertEqual(actual, expected)

    def test_complete_offline_bundle(self) -> None:
        contents = self.app / "Contents"
        required = (
            "MacOS/MacFaceLock",
            "Resources/defaults/config.json",
            "Resources/runtime/MacFaceLockRuntime/MacFaceLockRuntime",
            "Resources/runtime/MacFaceLockRuntime/_internal/cv2/data/"
            "haarcascade_frontalface_default.xml",
            "Resources/LICENSE",
            "Resources/THIRD_PARTY_NOTICES.md",
            "Resources/BuildManifest.json",
        )
        for relative in required:
            self.assertTrue((contents / relative).exists(), relative)
        self.assertFalse(
            (self.app / "Contents/Library/LoginItems/Mac Face Lock Agent.app").exists()
        )
        self.assertFalse(any(self.app.rglob("MacFaceLockAgent")))
        archive_bytes = ZIP_PATH.read_bytes()
        self.assertNotIn(b"com.wuyi.mac-face-lock-agent.app", archive_bytes)
        manifest = json.loads(
            (contents / "Resources/BuildManifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["schema_version"], 3)
        self.assertRegex(manifest["source_commit"], r"^[0-9a-f]{40}$")
        source_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=PROJECT_DIR,
            text=True,
        ).strip()
        self.assertEqual(manifest["source_commit"], source_commit)
        self.assertEqual(manifest["scope"], "final_non_code_payload")
        self.assertTrue(manifest["files"])
        outer_plist = plistlib.loads((contents / "Info.plist").read_bytes())
        self.assertEqual(outer_plist["CFBundleShortVersionString"], "0.2.0")
        licenses = contents / "Resources/licenses"
        for relative in REQUIRED_LICENSES:
            path = licenses / relative
            self.assertTrue(path.is_file(), relative)
            self.assertGreater(path.stat().st_size, 100, relative)

    def test_bundle_contains_no_developer_or_python_dependency_paths(self) -> None:
        forbidden = (
            str(PROJECT_DIR).encode(),
            str(Path.home()).encode(),
            b"/.venv/",
            b"/usr/bin/python",
            b"/opt/homebrew/bin/python",
        )
        for path in self.app.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            found = find_forbidden_token(path, forbidden)
            self.assertIsNone(
                found,
                f"{path.relative_to(self.app)} contains {found!r}",
            )

    def test_manifest_matches_every_final_scoped_digest(self) -> None:
        manifest = self.app / "Contents/Resources/BuildManifest.json"
        result = subprocess.run(
            ["python3", str(MANIFEST_TOOL), "verify", str(self.app), str(manifest)],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(manifest.read_text(encoding="utf-8"))
        manifested_paths = {item["path"] for item in document["files"]}
        required_manifest_paths = {
            "Contents/Info.plist",
            "Contents/Resources/LICENSE",
            "Contents/Resources/THIRD_PARTY_NOTICES.md",
            "Contents/Resources/defaults/config.json",
            "Contents/Resources/help/legacy-install-resolution.md",
            "Contents/Resources/launchd/com.wuyi.mac-face-lock-release.plist",
            "Contents/Resources/runtime/MacFaceLockRuntime/_internal/base_library.zip",
            "Contents/Resources/runtime/MacFaceLockRuntime/_internal/cv2/data/"
            "haarcascade_frontalface_default.xml",
        }
        required_manifest_paths.update(
            f"Contents/Resources/licenses/{relative}"
            for relative in REQUIRED_LICENSES
        )
        self.assertTrue(
            required_manifest_paths.issubset(manifested_paths),
            sorted(required_manifest_paths - manifested_paths),
        )
        self.assertEqual(
            {item["reason"] for item in document["excluded_files"]},
            {"manifest_self", "code_signature", "mach_o_code"},
        )

    def test_extracted_release_environment_launches_without_developer_tools(self) -> None:
        resources = self.app / "Contents/Resources"
        executable = self.app / "Contents/MacOS/MacFaceLock"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            support = temporary / "Library/Application Support/Mac Face Lock"
            (support / "config").mkdir(parents=True)
            (support / "data").mkdir()
            (support / "logs").mkdir()
            (support / "config/config.json").write_bytes(
                (resources / "defaults/config.json").read_bytes()
            )
            result = subprocess.run(
                [
                    str(executable),
                    "--internal-runtime",
                    "--resources-dir",
                    str(resources),
                    "--support-dir",
                    str(support),
                    "diagnose",
                ],
                capture_output=True,
                text=True,
                timeout=15,
                env={
                    **os.environ,
                    "CFFIXED_USER_HOME": directory,
                    "HOME": directory,
                },
            )

            self.assertIn(result.returncode, {0, 10, 11, 20}, result.stderr)
            self.assertIn('"event": "diagnosis_complete"', result.stdout)

    def test_packaged_main_executable_accepts_exact_release_arguments(self) -> None:
        resources = self.app / "Contents/Resources"
        launcher = self.app / "Contents/MacOS/MacFaceLock"
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory) / "Library/Application Support/Mac Face Lock"
            (support / "config").mkdir(parents=True)
            (support / "data").mkdir()
            (support / "logs").mkdir()
            (support / "config/config.json").write_bytes(
                (resources / "defaults/config.json").read_bytes()
            )
            (support / "data/control.json").write_text(
                '{"protection_enabled":false}\n',
                encoding="utf-8",
            )
            np.save(
                support / "data/owner_face.npy",
                np.ones((2, 96 * 96), dtype="float32"),
            )
            process = subprocess.Popen(
                [
                    str(launcher),
                    "--internal-runtime",
                    "--resources-dir",
                    str(resources),
                    "--support-dir",
                    str(support),
                    "agent",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={
                    **os.environ,
                    "CFFIXED_USER_HOME": directory,
                    "HOME": directory,
                },
            )
            try:
                deadline = time.monotonic() + 10
                output = ""
                while time.monotonic() < deadline:
                    readable, _, _ = select.select(
                        [process.stdout],
                        [],
                        [],
                        0.25,
                    )
                    if not readable:
                        if process.poll() is not None:
                            break
                        continue
                    line = process.stdout.readline()
                    if line:
                        output += line
                        if '"event": "agent_started"' in output:
                            break
                    elif process.poll() is not None:
                        break
                self.assertIn(
                    '"event": "agent_started"',
                    output,
                    process.stderr.read() if process.poll() is not None else output,
                )
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                if process.stdout is not None:
                    process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()


if __name__ == "__main__":
    unittest.main()
