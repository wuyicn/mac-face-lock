#!/usr/bin/env python3
"""macOS lock-screen control."""

from __future__ import annotations

import subprocess
from pathlib import Path


LOCK_COMMANDS = [
    [
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
        "-suspend",
    ],
    [
        "/usr/bin/osascript",
        "-e",
        'tell application "System Events" to keystroke "q" using {control down, command down}',
    ],
    ["/usr/bin/pmset", "displaysleepnow"],
]


def lock_screen(dry_run: bool = False) -> None:
    if dry_run:
        return
    errors: list[str] = []
    for command in LOCK_COMMANDS:
        if not Path(command[0]).exists():
            errors.append(f"not found: {command[0]}")
            continue
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            return
        errors.append(
            f"{command[0]} exited {result.returncode}: {result.stderr.strip() or result.stdout.strip()}"
        )
    raise RuntimeError("; ".join(errors))
