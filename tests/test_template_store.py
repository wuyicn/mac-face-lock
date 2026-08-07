from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from template_store import replace_owner_template


class TemplateStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def test_atomic_template_replacement_keeps_old_profile_on_invalid_candidate(self):
        destination = self.root / "owner_face.npy"
        np.save(destination, np.ones((2, 96 * 96), dtype="float32"))

        with self.assertRaises(ValueError):
            replace_owner_template(np.array([np.nan], dtype="float32"), destination)

        self.assertTrue(np.isfinite(np.load(destination)).all())

    def test_valid_template_replaces_profile_as_float32(self):
        destination = self.root / "data" / "owner_face.npy"
        candidate = np.full((3, 96 * 96), 0.25, dtype="float32")

        replace_owner_template(candidate, destination)

        stored = np.load(destination)
        self.assertEqual(stored.dtype, np.dtype("float32"))
        np.testing.assert_array_equal(stored, candidate)

    def test_template_must_be_finite_float32_matrix_with_two_samples(self):
        invalid_candidates = (
            np.ones((2, 96 * 96), dtype="float64"),
            np.ones((96 * 96,), dtype="float32"),
            np.ones((1, 96 * 96), dtype="float32"),
            np.ones((2, 96 * 96 - 1), dtype="float32"),
            np.full((2, 96 * 96), np.inf, dtype="float32"),
        )

        for candidate in invalid_candidates:
            with self.subTest(shape=candidate.shape, dtype=candidate.dtype):
                with self.assertRaises(ValueError):
                    replace_owner_template(candidate, self.root / "owner_face.npy")

    def test_failed_atomic_replace_preserves_profile_and_removes_temporary_file(self):
        destination = self.root / "owner_face.npy"
        original = np.ones((2, 96 * 96), dtype="float32")
        np.save(destination, original)
        candidate = np.zeros((2, 96 * 96), dtype="float32")

        with (
            patch("template_store.os.replace", side_effect=OSError("replace failed")),
            self.assertRaisesRegex(OSError, "replace failed"),
        ):
            replace_owner_template(candidate, destination)

        np.testing.assert_array_equal(np.load(destination), original)
        self.assertEqual(list(self.root.glob("*.tmp.npy")), [])


if __name__ == "__main__":
    unittest.main()
