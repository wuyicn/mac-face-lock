from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

from runtime_paths import RuntimePaths
from state_store import now_iso


CONTROL_PATH = RuntimePaths.for_source(
    Path(__file__).resolve().parent
).control_path


@dataclass(frozen=True)
class ControlState:
    protection_enabled: bool
    updated_at: str | None


def read_control(
    path: Path = CONTROL_PATH,
    fallback: ControlState = ControlState(True, None),
) -> ControlState:
    if not path.exists():
        return fallback
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return fallback
    if not isinstance(payload, dict):
        return fallback
    schema_version = payload.get("schema_version")
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != 1
    ):
        return fallback
    enabled = payload.get("protection_enabled")
    if not isinstance(enabled, bool):
        return fallback
    updated_at = payload.get("updated_at")
    if updated_at is not None and not isinstance(updated_at, str):
        return fallback
    return ControlState(enabled, updated_at)


def write_control(enabled: bool, path: Path = CONTROL_PATH) -> ControlState:
    state = ControlState(enabled, now_iso())
    payload = {
        "schema_version": 1,
        "protection_enabled": state.protection_enabled,
        "updated_at": state.updated_at,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f"{path.stem}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        tmp = Path(handle.name)
        json.dump(payload, handle, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    return state
