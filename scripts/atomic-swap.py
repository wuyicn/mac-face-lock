#!/usr/bin/env python3
"""Atomically publish a sibling path, swapping with an existing destination."""

from __future__ import annotations

import ctypes
import errno
import os
import sys
from pathlib import Path


AT_FDCWD = -2
RENAME_SWAP = 0x00000002
INJECTION_ENV = "MAC_FACE_LOCK_ATOMIC_SWAP_INJECT"


def fail_if_injected(point: str) -> None:
    if os.environ.get(INJECTION_ENV) == point:
        raise OSError(errno.EINTR, f"injected failure {point}")


def rename_swap(source: Path, destination: Path) -> None:
    if source.parent != destination.parent:
        raise ValueError("source and destination must be siblings")
    if not source.exists():
        raise FileNotFoundError(source)

    fail_if_injected("before")
    if not destination.exists():
        os.rename(source, destination)
    else:
        libc = ctypes.CDLL(None, use_errno=True)
        renameatx_np = libc.renameatx_np
        renameatx_np.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        renameatx_np.restype = ctypes.c_int
        result = renameatx_np(
            AT_FDCWD,
            os.fsencode(source),
            AT_FDCWD,
            os.fsencode(destination),
            RENAME_SWAP,
        )
        if result != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), f"{source} <-> {destination}")
    fail_if_injected("after")


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} SOURCE DESTINATION", file=sys.stderr)
        return 64
    try:
        rename_swap(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (OSError, ValueError) as error:
        print(f"atomic publish failed: {error}", file=sys.stderr)
        return 75
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
