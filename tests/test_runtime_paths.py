import tempfile
import unittest
from dataclasses import FrozenInstanceError
from pathlib import Path

from runtime_paths import RuntimePaths


class RuntimePathsTests(unittest.TestCase):
    def test_release_paths_derive_every_child_from_resolved_bases(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            root = Path(directory)
            resources = root / "resolved-resources"
            support = root / "resolved-support"
            resources.mkdir()
            support.mkdir()
            resources_link = root / "resources-link"
            support_link = root / "support-link"
            resources_link.symlink_to(resources, target_is_directory=True)
            support_link.symlink_to(support, target_is_directory=True)

            paths = RuntimePaths.for_release(
                resources_link.relative_to(Path.cwd()),
                support_link.relative_to(Path.cwd()),
            )

            self.assertEqual(paths.resources_dir, resources.resolve())
            self.assertEqual(paths.support_dir, support.resolve())
            self.assertEqual(
                paths.config_path,
                support.resolve() / "config" / "config.json",
            )
            self.assertEqual(paths.data_dir, support.resolve() / "data")
            self.assertEqual(paths.logs_dir, support.resolve() / "logs")
            self.assertEqual(
                paths.owner_face_path,
                support.resolve() / "data" / "owner_face.npy",
            )
            self.assertEqual(
                paths.state_path,
                support.resolve() / "data" / "state.json",
            )
            self.assertEqual(
                paths.control_path,
                support.resolve() / "data" / "control.json",
            )
            self.assertEqual(
                paths.activity_path,
                support.resolve() / "data" / "activity.jsonl",
            )
            self.assertEqual(
                paths.evidence_dir,
                support.resolve() / "data" / "evidence",
            )

    def test_source_paths_preserve_existing_layout_and_enabled_fallback(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            root = Path(directory)
            relative_root = root.relative_to(Path.cwd())

            paths = RuntimePaths.for_source(relative_root)

            self.assertEqual(paths.resources_dir, root.resolve())
            self.assertEqual(paths.support_dir, root.resolve())
            self.assertEqual(
                paths.config_path,
                root.resolve() / "config" / "config.json",
            )
            self.assertEqual(
                paths.owner_face_path,
                root.resolve() / "data" / "owner_face.npy",
            )
            self.assertTrue(paths.control_fallback_enabled)

    def test_release_missing_control_fallback_is_disabled(self):
        paths = RuntimePaths.for_release(
            Path("/Applications/App/Resources"),
            Path("/tmp/support"),
        )

        self.assertFalse(paths.control_fallback_enabled)

    def test_runtime_paths_are_frozen(self):
        paths = RuntimePaths.for_source(Path("/tmp/source"))

        with self.assertRaises(FrozenInstanceError):
            paths.support_dir = Path("/tmp/other")  # type: ignore[misc]
        with self.assertRaises(FrozenInstanceError):
            paths.control_fallback_enabled = False  # type: ignore[misc]

    def test_ensure_writable_directories_only_creates_support_children(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "resources-do-not-create"
            support = root / "support"
            paths = RuntimePaths.for_release(resources, support)

            paths.ensure_writable_directories()
            paths.ensure_writable_directories()

            self.assertFalse(resources.exists())
            self.assertFalse(paths.config_path.exists())
            self.assertEqual(
                {
                    path.relative_to(support)
                    for path in support.rglob("*")
                    if path.is_dir()
                },
                {
                    Path("config"),
                    Path("data"),
                    Path("data/evidence"),
                    Path("logs"),
                },
            )

    def test_ensure_writable_directories_does_not_write_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "resources"
            resources.mkdir()
            sentinel = resources / "bundled.json"
            sentinel.write_text('{"bundled": true}\n', encoding="utf-8")
            before = {
                path.relative_to(resources): path.read_bytes()
                for path in resources.rglob("*")
                if path.is_file()
            }
            paths = RuntimePaths.for_release(resources, root / "support")

            paths.ensure_writable_directories()

            after = {
                path.relative_to(resources): path.read_bytes()
                for path in resources.rglob("*")
                if path.is_file()
            }
            self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
