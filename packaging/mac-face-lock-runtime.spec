# -*- mode: python ; coding: utf-8 -*-
"""Pinned arm64 onedir runtime for the customer release.

PyObjC framework modules are dynamic imports in the Agent permission probes, so
they are collected explicitly alongside OpenCV's cascade resources.
"""

from pathlib import Path

import cv2
import numpy
from PyInstaller.utils.hooks import collect_submodules


project = Path(SPEC).resolve().parents[1]
assert numpy.__version__
hidden_imports = []
for package in (
    "AVFoundation",
    "AppKit",
    "Foundation",
    "Quartz",
    "PyObjCTools",
    "pynput",
):
    hidden_imports.extend(collect_submodules(package))

analysis = Analysis(
    [str(project / "runtime_cli.py")],
    pathex=[str(project)],
    binaries=[],
    datas=[
        (str(path), "cv2/data")
        for path in sorted(Path(cv2.data.haarcascades).glob("*.xml"))
    ],
    hiddenimports=sorted(set(hidden_imports)),
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["pytest", "IPython", "tkinter"],
    noarchive=False,
    optimize=1,
)
pyz = PYZ(analysis.pure)
executable = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="MacFaceLockRuntime",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    target_arch="arm64",
)
collection = COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="MacFaceLockRuntime",
)
