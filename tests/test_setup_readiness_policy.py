import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
SETUP_MODELS = PROJECT_DIR / "src" / "app" / "SetupModels.swift"


@unittest.skipUnless(shutil.which("xcrun"), "requires the macOS Swift toolchain")
class SetupReadinessPolicyTests(unittest.TestCase):
    def test_application_code_cannot_construct_readiness_directly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            probe = Path(directory) / "SetupReadinessConstructionProbe.swift"
            probe.write_text(
                """
func constructReadinessWithoutEvaluation() -> SetupReadiness {
    SetupReadiness(checks: [:], requiredChecks: [])
}
""",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-parse-as-library",
                    "-typecheck",
                    str(SETUP_MODELS),
                    str(probe),
                ],
                cwd=PROJECT_DIR,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(
            result.returncode,
            0,
            "SetupReadiness must only be constructible through evaluate",
        )
        self.assertRegex(
            result.stderr,
            r"initializer is inaccessible due to 'private' protection level",
        )


if __name__ == "__main__":
    unittest.main()
