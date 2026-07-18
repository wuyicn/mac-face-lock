from __future__ import annotations

import hashlib
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
RELEASE_ROOT = PROJECT_DIR / "dist" / "release"
ZIP_PATH = RELEASE_ROOT / "Mac-Face-Lock-0.2.0-beta-arm64.zip"
CHECKSUM_PATH = ZIP_PATH.with_suffix(ZIP_PATH.suffix + ".sha256")


class ReleaseBundlePolicyTests(unittest.TestCase):
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
            "Mac Face Lock Agent.app",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "BuildManifest.json",
            "codesign",
            "ditto",
            "shasum",
        ):
            self.assertIn(token, release)


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
            "Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent",
            "Resources/defaults/config.json",
            "Resources/runtime/MacFaceLockRuntime/MacFaceLockRuntime",
            "Resources/LICENSE",
            "Resources/THIRD_PARTY_NOTICES.md",
            "Resources/BuildManifest.json",
        )
        for relative in required:
            self.assertTrue((contents / relative).exists(), relative)
        manifest = json.loads(
            (contents / "Resources/BuildManifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["schema_version"], 1)
        self.assertTrue(manifest["files"])
        plist = plistlib.loads(
            (
                contents
                / "Library/LoginItems/Mac Face Lock Agent.app/Contents/Info.plist"
            ).read_bytes()
        )
        self.assertEqual(plist["LSMinimumSystemVersion"], "12.0")

    def test_bundle_contains_no_developer_or_python_dependency_paths(self) -> None:
        forbidden = (
            str(PROJECT_DIR).encode(),
            str(Path.home()).encode(),
            b"/.venv/",
            b"/usr/bin/python",
            b"/opt/homebrew/bin/python",
        )
        for path in self.app.rglob("*"):
            if not path.is_file() or path.is_symlink() or path.stat().st_size > 20_000_000:
                continue
            data = path.read_bytes()
            for token in forbidden:
                self.assertNotIn(token, data, str(path.relative_to(self.app)))

    def test_extracted_release_environment_launches_without_developer_tools(self) -> None:
        executable = self.app / "Contents/MacOS/MacFaceLock"
        process = subprocess.Popen(
            [str(executable)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(2)
            self.assertIsNone(
                process.poll(),
                process.stderr.read() if process.poll() is not None else "",
            )
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            if process.stderr is not None:
                process.stderr.close()

    def test_packaged_launcher_accepts_exact_release_arguments(self) -> None:
        resources = self.app / "Contents/Resources"
        launcher = (
            self.app
            / "Contents/Library/LoginItems/Mac Face Lock Agent.app"
            / "Contents/MacOS/MacFaceLockAgent"
        )
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory) / "Mac Face Lock"
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
                    "--resources-dir",
                    str(resources),
                    "--support-dir",
                    str(support),
                    "agent",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
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
