from __future__ import annotations

import json
import os
import threading
import uuid
from pathlib import Path
from typing import Any

from runtime_paths import RuntimePaths
from state_store import now_iso


ACTIVITY_PATH = RuntimePaths.for_source(
    Path(__file__).resolve().parent
).activity_path
_WRITE_LOCK = threading.Lock()


def append_activity(
    event_type: str,
    title: str,
    detail: str,
    severity: str,
    metadata: dict[str, Any] | None = None,
    *,
    path: Path = ACTIVITY_PATH,
    event_id: str | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    event = {
        "schema_version": 1,
        "id": event_id or str(uuid.uuid4()),
        "timestamp": timestamp or now_iso(),
        "type": event_type,
        "title": title,
        "detail": detail,
        "severity": severity,
        "metadata": metadata or {},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
    with _WRITE_LOCK:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    return event
