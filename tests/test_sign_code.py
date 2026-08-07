from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
SIGN_CODE = PROJECT_DIR / "scripts" / "sign-code.sh"
IDENTIFIER = "com.wuyi.mac-face-lock.app"
STABLE_IDENTITY = "Apple Development: Developer (TEAMID1234)"


class SignCodeTests(unittest.TestCase):
    def run_signer(self, signing_identity: str | None) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            bin_directory = temporary / "bin"
            bin_directory.mkdir()
            log_path = temporary / "codesign-arguments.txt"
            fake_codesign = bin_directory / "codesign"
            fake_codesign.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$MAC_FACE_LOCK_CODESIGN_LOG\"\n",
                encoding="utf-8",
            )
            fake_codesign.chmod(
                fake_codesign.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP
            )
            target = temporary / "Mac Face Lock.app"
            target.mkdir()
            environment = {
                **os.environ,
                "PATH": f"{bin_directory}:{os.environ['PATH']}",
                "MAC_FACE_LOCK_CODESIGN_LOG": str(log_path),
            }
            if signing_identity is None:
                environment.pop("MAC_FACE_LOCK_SIGNING_IDENTITY", None)
            else:
                environment["MAC_FACE_LOCK_SIGNING_IDENTITY"] = signing_identity

            result = subprocess.run(
                [
                    "/bin/bash",
                    str(SIGN_CODE),
                    "--deep",
                    "--identifier",
                    IDENTIFIER,
                    str(target),
                ],
                cwd=PROJECT_DIR,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            return log_path.read_text(encoding="utf-8").splitlines()

    def test_ad_hoc_signing_keeps_the_explicit_unified_requirement(self) -> None:
        arguments = self.run_signer(None)

        self.assertIn("-", arguments)
        self.assertIn("--deep", arguments)
        self.assertIn("-i", arguments)
        self.assertIn(IDENTIFIER, arguments)
        self.assertIn(
            f'-r=designated => identifier "{IDENTIFIER}"',
            arguments,
        )

    def test_stable_signing_uses_certificate_derived_requirement(self) -> None:
        arguments = self.run_signer(STABLE_IDENTITY)

        self.assertIn(STABLE_IDENTITY, arguments)
        self.assertIn("--deep", arguments)
        self.assertIn(IDENTIFIER, arguments)
        self.assertFalse(
            any(argument.startswith("-r=") for argument in arguments),
            arguments,
        )


if __name__ == "__main__":
    unittest.main()
