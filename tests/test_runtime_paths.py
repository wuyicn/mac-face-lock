import unittest
from pathlib import Path

from runtime_paths import RuntimePaths


class RuntimePathsTests(unittest.TestCase):
    def test_release_paths_keep_resources_read_only_and_state_in_support(self):
        paths = RuntimePaths.for_release(
            Path("/Applications/App/Resources"),
            Path("/tmp/support"),
        )
        self.assertEqual(paths.config_path, Path("/tmp/support/config/config.json"))
        self.assertEqual(paths.owner_face_path, Path("/tmp/support/data/owner_face.npy"))
        self.assertEqual(paths.logs_dir, Path("/tmp/support/logs"))

    def test_source_paths_preserve_existing_layout(self):
        paths = RuntimePaths.for_source(Path("/tmp/source"))
        self.assertEqual(paths.config_path, Path("/tmp/source/config/config.json"))
        self.assertEqual(paths.owner_face_path, Path("/tmp/source/data/owner_face.npy"))


if __name__ == "__main__":
    unittest.main()
