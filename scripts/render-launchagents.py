#!/usr/bin/env python3
"""Render repository LaunchAgent templates for a concrete project path."""

from __future__ import annotations

import argparse
import os
import plistlib
import tempfile
from pathlib import Path


AGENT_LABEL = "com.wuyi.mac-face-lock-agent"
UI_LABEL = "com.wuyi.mac-face-lock-status"
TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "launchd"


def _write_plist_atomically(value: dict[str, object], destination: Path) -> None:
    with tempfile.NamedTemporaryFile(
        mode="wb", dir=destination.parent, prefix=f".{destination.name}.", delete=False
    ) as handle:
        temporary_path = Path(handle.name)
        try:
            plistlib.dump(value, handle, fmt=plistlib.FMT_XML, sort_keys=False)
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise
    temporary_path.replace(destination)


def render_launchagents(project_dir: Path, output_dir: Path) -> tuple[Path, Path]:
    root = project_dir.expanduser().resolve(strict=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    values = {
        AGENT_LABEL: {
            "program": root / "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent",
            "arguments": [str(root)],
            "stdout": root / "logs/agent.out.log",
            "stderr": root / "logs/agent.err.log",
        },
        UI_LABEL: {
            "program": root / "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock",
            "arguments": [str(root)],
            "stdout": root / "logs/status.out.log",
            "stderr": root / "logs/status.err.log",
        },
    }

    rendered_paths: list[Path] = []
    for label in (AGENT_LABEL, UI_LABEL):
        template_path = TEMPLATE_DIR / f"{label}.plist"
        with template_path.open("rb") as handle:
            launchagent = plistlib.load(handle)
        settings = values[label]
        launchagent["ProgramArguments"] = [
            str(settings["program"]),
            *settings["arguments"],
        ]
        launchagent["WorkingDirectory"] = str(root)
        launchagent["StandardOutPath"] = str(settings["stdout"])
        launchagent["StandardErrorPath"] = str(settings["stderr"])
        environment = launchagent.get("EnvironmentVariables")
        if isinstance(environment, dict):
            environment.pop("PYTHONPATH", None)

        destination = output_dir / template_path.name
        _write_plist_atomically(launchagent, destination)
        rendered_paths.append(destination)

    return rendered_paths[0], rendered_paths[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    arguments = parser.parse_args()

    for path in render_launchagents(arguments.project_dir, arguments.output_dir):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
