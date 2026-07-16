#!/usr/bin/env python3
"""Tests for portable LaunchAgent plist rendering."""

from __future__ import annotations

import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
RENDERER_PATH = PROJECT_DIR / "scripts" / "render-launchagents.py"
SPEC = importlib.util.spec_from_file_location("launchagent_renderer", RENDERER_PATH)
if SPEC is None or SPEC.loader is None:
    raise ImportError(f"Unable to load renderer from {RENDERER_PATH}")
RENDERER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RENDERER)
render_launchagents = RENDERER.render_launchagents


class LaunchAgentRendererTests(unittest.TestCase):
    def test_renders_arbitrary_project_path_without_template_tokens(self):
        with tempfile.TemporaryDirectory(prefix="Mac 人脸 & Lock ") as directory:
            root = Path(directory).resolve()
            output = root / "generated"
            agent_path, ui_path = render_launchagents(root, output)
            agent = plistlib.loads(agent_path.read_bytes())
            ui = plistlib.loads(ui_path.read_bytes())
            self.assertEqual(agent["WorkingDirectory"], str(root))
            self.assertEqual(ui["WorkingDirectory"], str(root))
            self.assertEqual(agent["ProgramArguments"][1], str(root))
            self.assertEqual(ui["ProgramArguments"][1], str(root))
            self.assertNotIn("__PROJECT_DIR__", agent_path.read_text())
            self.assertNotIn("__PROJECT_DIR__", ui_path.read_text())

    def test_generated_agent_uses_built_launcher_without_pythonpath(self):
        with tempfile.TemporaryDirectory(prefix="Mac Face Lock ") as directory:
            root = Path(directory).resolve()
            agent_path, _ = render_launchagents(root, root / "generated")
            agent = plistlib.loads(agent_path.read_bytes())
            self.assertEqual(
                agent["ProgramArguments"][0],
                str(root / "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"),
            )
            self.assertNotIn("PYTHONPATH", agent.get("EnvironmentVariables", {}))

    def test_preserves_distinct_ui_and_agent_restart_policies(self):
        with tempfile.TemporaryDirectory(prefix="Mac Face Lock ") as directory:
            root = Path(directory).resolve()
            agent_path, ui_path = render_launchagents(root, root / "generated")
            agent = plistlib.loads(agent_path.read_bytes())
            ui = plistlib.loads(ui_path.read_bytes())

            self.assertIs(agent["RunAtLoad"], True)
            self.assertIs(agent["KeepAlive"], True)
            self.assertIs(ui["RunAtLoad"], True)
            self.assertEqual(ui["KeepAlive"], {"SuccessfulExit": False})


if __name__ == "__main__":
    unittest.main()
