#!/usr/bin/env python3
"""Behavior tests for crash-safe unified app publication."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
SWAP_HELPER = PROJECT_DIR / "scripts" / "atomic-swap.py"
BUILD_SCRIPT = PROJECT_DIR / "scripts" / "build-status-app.sh"


class AtomicSwapTests(unittest.TestCase):
    def run_swap(
        self, source: Path, destination: Path, injection: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if injection is not None:
            environment["MAC_FACE_LOCK_ATOMIC_SWAP_INJECT"] = injection
        return subprocess.run(
            [str(SWAP_HELPER), str(source), str(destination)],
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_absent_destination_uses_atomic_rename(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "staging"
            destination = root / "current"
            source.mkdir()
            (source / "version").write_text("new", encoding="utf-8")

            result = self.run_swap(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(source.exists())
            self.assertEqual((destination / "version").read_text(), "new")

    @unittest.skipUnless(sys.platform == "darwin", "requires renameatx_np")
    def test_existing_destination_is_swapped_in_one_operation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "staging"
            destination = root / "current"
            source.mkdir()
            destination.mkdir()
            (source / "version").write_text("new", encoding="utf-8")
            (destination / "version").write_text("old", encoding="utf-8")

            result = self.run_swap(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((destination / "version").read_text(), "new")
            self.assertEqual((source / "version").read_text(), "old")

    def test_injected_failure_before_swap_keeps_both_paths_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "staging"
            destination = root / "current"
            source.mkdir()
            destination.mkdir()
            (source / "version").write_text("new", encoding="utf-8")
            (destination / "version").write_text("old", encoding="utf-8")

            result = self.run_swap(source, destination, "before")

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((destination / "version").read_text(), "old")
            self.assertEqual((source / "version").read_text(), "new")

    @unittest.skipUnless(sys.platform == "darwin", "requires renameatx_np")
    def test_injected_failure_after_swap_leaves_canonical_destination_new(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "staging"
            destination = root / "current"
            source.mkdir()
            destination.mkdir()
            (source / "version").write_text("new", encoding="utf-8")
            (destination / "version").write_text("old", encoding="utf-8")

            result = self.run_swap(source, destination, "after")

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((destination / "version").read_text(), "new")
            self.assertEqual((source / "version").read_text(), "old")


class BuildRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name) / "project"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "src" / "app").mkdir(parents=True)
        (self.root / "src" / "agent-launcher").mkdir(parents=True)
        (self.root / "launchd").mkdir()
        (self.root / ".test-bin").mkdir()
        shutil.copy2(BUILD_SCRIPT, self.root / "scripts" / BUILD_SCRIPT.name)
        shutil.copy2(
            PROJECT_DIR / "scripts" / "build-app.sh",
            self.root / "scripts" / "build-app.sh",
        )
        shutil.copy2(SWAP_HELPER, self.root / "scripts" / SWAP_HELPER.name)
        shutil.copy2(
            PROJECT_DIR / "src" / "app" / "Info.plist",
            self.root / "src" / "app" / "Info.plist",
        )
        shutil.copy2(
            PROJECT_DIR / "src" / "app" / "AppIcon.icns",
            self.root / "src" / "app" / "AppIcon.icns",
        )
        (self.root / "src" / "app" / "main.swift").write_text(
            "@main enum App { static func main() {} }\n", encoding="utf-8"
        )
        (self.root / "src" / "agent-launcher" / "main.swift").write_text(
            "@main enum Agent { static func main() {} }\n", encoding="utf-8"
        )
        shutil.copy2(
            PROJECT_DIR / "launchd" / "com.wuyi.mac-face-lock-release.plist",
            self.root / "launchd" / "com.wuyi.mac-face-lock-release.plist",
        )
        self._write_tool(
            "xcrun",
            """#!/bin/bash
set -e
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then shift; printf '#!/bin/sh\n' > "$1"; exit 0; fi
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
if [[ " $* " == *" --sign "* ]]; then
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
        runtime = self.root / "dist/runtime/MacFaceLockRuntime/MacFaceLockRuntime"
        runtime.parent.mkdir(parents=True)
        runtime.write_text("#!/bin/sh\n", encoding="utf-8")
        runtime.chmod(0o755)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_tool(self, name: str, body: str) -> None:
        path = self.root / ".test-bin" / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def _run_build(
        self, injection: str | None = None, **updates: str
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.root / '.test-bin'}:{environment['PATH']}"
        if injection is not None:
            environment["MAC_FACE_LOCK_ATOMIC_SWAP_INJECT"] = injection
        environment.update(updates)
        return subprocess.run(
            [str(self.root / "scripts" / "build-status-app.sh")],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=environment,
        )

    def _generation(self, bundle: Path) -> int:
        return int(
            (bundle / "Contents" / "Resources" / "BuildGeneration").read_text()
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires renameatx_np")
    def test_rerun_recovers_failure_before_swap_without_losing_current(self) -> None:
        initial = self._run_build()
        self.assertEqual(initial.returncode, 0, initial.stderr)
        app = self.root / "dist" / "Mac Face Lock.app"
        old_generation = self._generation(app)

        interrupted = self._run_build("before")
        self.assertNotEqual(interrupted.returncode, 0)
        self.assertEqual(self._generation(app), old_generation)
        self.assertTrue((self.root / "dist" / ".Mac Face Lock.app.building").is_dir())

        recovered = self._run_build()
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertGreater(self._generation(app), old_generation)
        self.assertFalse((self.root / "dist" / ".Mac Face Lock.app.building").exists())

    def test_first_build_rerun_discards_incomplete_unsigned_staging(self) -> None:
        app = self.root / "dist" / "Mac Face Lock.app"
        staging = self.root / "dist" / ".Mac Face Lock.app.building"

        interrupted = self._run_build(FAKE_CODESIGN_FAIL_SIGN="1")
        self.assertNotEqual(interrupted.returncode, 0)
        self.assertFalse(app.exists())
        self.assertTrue(staging.is_dir())
        self.assertFalse((staging / ".test-signed").exists())

        recovered = self._run_build()
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertTrue(app.is_dir())
        self.assertTrue((app / ".test-signed").is_file())
        self.assertFalse(staging.exists())

    @unittest.skipUnless(sys.platform == "darwin", "requires renameatx_np")
    def test_rerun_recovers_failure_after_swap_cleanup(self) -> None:
        initial = self._run_build()
        self.assertEqual(initial.returncode, 0, initial.stderr)
        app = self.root / "dist" / "Mac Face Lock.app"
        old_generation = self._generation(app)

        interrupted = self._run_build("after")
        self.assertNotEqual(interrupted.returncode, 0)
        published_generation = self._generation(app)
        self.assertGreater(published_generation, old_generation)
        self.assertTrue((self.root / "dist" / ".Mac Face Lock.app.building").is_dir())

        recovered = self._run_build()
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertGreaterEqual(self._generation(app), published_generation)
        self.assertFalse((self.root / "dist" / ".Mac Face Lock.app.building").exists())


if __name__ == "__main__":
    unittest.main()
