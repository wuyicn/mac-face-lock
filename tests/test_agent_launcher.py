#!/usr/bin/env python3
"""Subprocess tests for the portable Agent launcher contract."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class AgentLauncherSubprocessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = tempfile.TemporaryDirectory()
        cls.launcher = Path(cls.temporary_directory.name) / "MacFaceLockAgent"
        subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-parse-as-library",
                "-target",
                "arm64-apple-macosx12.0",
                str(PROJECT_DIR / "src" / "agent-launcher" / "main.swift"),
                "-o",
                str(cls.launcher),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary_directory.cleanup()

    def test_no_argument_exits_64_with_concise_error(self) -> None:
        result = subprocess.run(
            [str(self.launcher)], capture_output=True, text=True
        )

        self.assertEqual(result.returncode, 64)
        self.assertEqual(result.stdout, "")
        self.assertIn("expected one absolute project directory argument", result.stderr)

    def test_missing_local_environment_exits_78_with_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.run(
                [str(self.launcher), str(root)], capture_output=True, text=True
            )

        self.assertEqual(result.returncode, 78)
        self.assertEqual(result.stdout, "")
        self.assertIn(str(root / ".venv" / "bin" / "python"), result.stderr)

    def test_valid_project_execs_python_with_unbuffered_agent_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            python = root / ".venv" / "bin" / "python"
            agent = root / "agent.py"
            python.parent.mkdir(parents=True)
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n', encoding="utf-8")
            python.chmod(0o755)
            agent.write_text("print('ok')\n", encoding="utf-8")

            result = subprocess.run(
                [str(self.launcher), str(root)], capture_output=True, text=True
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.splitlines(), ["-u", str(agent)])


if __name__ == "__main__":
    unittest.main()
