from __future__ import annotations

import os
import tempfile
from pathlib import Path

import numpy as np


TEMPLATE_COLUMNS = 96 * 96


def validate_owner_template(candidate: np.ndarray) -> None:
    if not isinstance(candidate, np.ndarray):
        raise ValueError("Owner template must be a NumPy array")
    if candidate.dtype != np.dtype("float32"):
        raise ValueError("Owner template must use float32 values")
    if candidate.ndim != 2:
        raise ValueError("Owner template must be a two-dimensional matrix")
    if candidate.shape[0] < 2:
        raise ValueError("Owner template must contain at least two samples")
    if candidate.shape[1] != TEMPLATE_COLUMNS:
        raise ValueError(
            f"Owner template must contain exactly {TEMPLATE_COLUMNS} columns"
        )
    if not np.isfinite(candidate).all():
        raise ValueError("Owner template must contain only finite values")


def replace_owner_template(candidate: np.ndarray, destination: Path) -> None:
    validate_owner_template(candidate)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=destination.parent,
            prefix=f".{destination.stem}.",
            suffix=".tmp.npy",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
        np.save(temporary_path, candidate, allow_pickle=False)
        stored = np.load(temporary_path, allow_pickle=False)
        validate_owner_template(stored)
        if not np.array_equal(stored, candidate):
            raise ValueError("Stored owner template did not match the candidate")
        os.replace(temporary_path, destination)
        temporary_path = None
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass
