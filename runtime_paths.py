from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RuntimePaths:
    resources_dir: Path
    support_dir: Path
    config_path: Path
    data_dir: Path
    logs_dir: Path
    control_fallback_enabled: bool

    @classmethod
    def for_source(cls, root: Path) -> "RuntimePaths":
        resolved_root = root.resolve()
        return cls(
            resources_dir=resolved_root,
            support_dir=resolved_root,
            config_path=resolved_root / "config" / "config.json",
            data_dir=resolved_root / "data",
            logs_dir=resolved_root / "logs",
            control_fallback_enabled=True,
        )

    @classmethod
    def for_release(
        cls,
        resources_dir: Path,
        support_dir: Path,
    ) -> "RuntimePaths":
        resolved_resources_dir = resources_dir.resolve()
        resolved_support_dir = support_dir.resolve()
        return cls(
            resources_dir=resolved_resources_dir,
            support_dir=resolved_support_dir,
            config_path=resolved_support_dir / "config" / "config.json",
            data_dir=resolved_support_dir / "data",
            logs_dir=resolved_support_dir / "logs",
            control_fallback_enabled=False,
        )

    @property
    def owner_face_path(self) -> Path:
        return self.data_dir / "owner_face.npy"

    @property
    def state_path(self) -> Path:
        return self.data_dir / "state.json"

    @property
    def control_path(self) -> Path:
        return self.data_dir / "control.json"

    @property
    def activity_path(self) -> Path:
        return self.data_dir / "activity.jsonl"

    @property
    def evidence_dir(self) -> Path:
        return self.data_dir / "evidence"

    def ensure_writable_directories(self) -> None:
        for directory in (
            self.config_path.parent,
            self.data_dir,
            self.logs_dir,
            self.evidence_dir,
        ):
            directory.mkdir(parents=True, exist_ok=True)
