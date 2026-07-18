#!/usr/bin/env python3
from __future__ import annotations

import shutil
import sys
import sysconfig
from pathlib import Path


class LicenseCollectionError(Exception):
    pass


def unique_match(site_packages: Path, pattern: str) -> Path:
    matches = sorted(site_packages.glob(pattern))
    if len(matches) != 1 or not matches[0].is_file():
        raise LicenseCollectionError(
            f"expected one installed license for {pattern}, found {len(matches)}"
        )
    return matches[0]


def collect(destination: Path) -> None:
    site_packages = Path(sysconfig.get_paths()["purelib"])
    python_license = (
        Path(sys.base_prefix)
        / "lib"
        / f"python{sys.version_info.major}.{sys.version_info.minor}"
        / "LICENSE.txt"
    )
    sources = {
        "Python/LICENSE.txt": python_license,
        "NumPy/LICENSE.txt": unique_match(
            site_packages,
            "numpy-*.dist-info/LICENSE.txt",
        ),
        "opencv-python/LICENSE.txt": unique_match(
            site_packages,
            "opencv_python-*.dist-info/LICENSE.txt",
        ),
        "opencv-python/LICENSE-3RD-PARTY.txt": unique_match(
            site_packages,
            "opencv_python-*.dist-info/LICENSE-3RD-PARTY.txt",
        ),
        "pynput/COPYING.LGPL": unique_match(
            site_packages,
            "pynput-*.dist-info/COPYING.LGPL",
        ),
        "six/LICENSE": unique_match(
            site_packages,
            "six-*.dist-info/LICENSE",
        ),
        "PyObjC/LICENSE.txt": unique_match(
            site_packages,
            "pyobjc_framework_cocoa-*.dist-info/licenses/LICENSE.txt",
        ),
    }
    for relative, source in sources.items():
        if not source.is_file() or source.stat().st_size <= 100:
            raise LicenseCollectionError(f"license unavailable: {source}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print(
            "usage: collect-release-licenses.py DESTINATION",
            file=sys.stderr,
        )
        return 64
    try:
        collect(Path(arguments[1]))
    except LicenseCollectionError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
