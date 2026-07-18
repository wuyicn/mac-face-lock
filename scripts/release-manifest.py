#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


MACH_O_MAGICS = {
    bytes.fromhex("feedface"),
    bytes.fromhex("cefaedfe"),
    bytes.fromhex("feedfacf"),
    bytes.fromhex("cffaedfe"),
    bytes.fromhex("cafebabe"),
    bytes.fromhex("bebafeca"),
    bytes.fromhex("cafebabf"),
    bytes.fromhex("bfbafeca"),
}
MANIFEST_RELATIVE_PATH = "Contents/Resources/BuildManifest.json"
MANIFEST_KEYS = {
    "architecture",
    "excluded_files",
    "files",
    "minimum_macos",
    "schema_version",
    "scope",
    "version",
}


class ManifestError(Exception):
    pass


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def is_mach_o(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(4) in MACH_O_MAGICS


def regular_files(app: Path) -> dict[str, Path]:
    return {
        path.relative_to(app).as_posix(): path
        for path in sorted(app.rglob("*"))
        if path.is_file() and not path.is_symlink()
    }


def exclusion_reason(relative: str, path: Path | None) -> str | None:
    if relative == MANIFEST_RELATIVE_PATH:
        return "manifest_self"
    if "_CodeSignature" in Path(relative).parts:
        return "code_signature"
    if path is not None and is_mach_o(path):
        return "mach_o_code"
    return None


def expected_scope(app: Path) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    paths = regular_files(app)
    paths.setdefault(MANIFEST_RELATIVE_PATH, app / MANIFEST_RELATIVE_PATH)
    files: list[dict[str, str]] = []
    excluded: list[dict[str, str]] = []
    for relative, path in sorted(paths.items()):
        reason = exclusion_reason(
            relative,
            path if path.exists() else None,
        )
        if reason is not None:
            excluded.append({"path": relative, "reason": reason})
        else:
            files.append({"path": relative, "sha256": digest(path)})
    return files, excluded


def generate(app: Path, manifest: Path) -> None:
    files, excluded = expected_scope(app)
    document = {
        "schema_version": 2,
        "version": "0.2.0-beta",
        "architecture": "arm64",
        "minimum_macos": "12.0",
        "scope": "final_non_code_payload",
        "files": files,
        "excluded_files": excluded,
    }
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(
        json.dumps(
            document,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def verify(app: Path, manifest: Path) -> None:
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"manifest unreadable: {error}") from error
    if not isinstance(document, dict) or set(document) != MANIFEST_KEYS:
        raise ManifestError("manifest schema keys mismatch")
    if document["schema_version"] != 2:
        raise ManifestError("manifest schema version mismatch")
    if document["scope"] != "final_non_code_payload":
        raise ManifestError("manifest scope mismatch")
    recorded_files = document["files"]
    recorded_excluded = document["excluded_files"]
    if not isinstance(recorded_files, list) or not isinstance(recorded_excluded, list):
        raise ManifestError("manifest lists are invalid")
    expected_files, expected_excluded = expected_scope(app)
    expected_file_paths = [item["path"] for item in expected_files]
    recorded_file_paths = [
        item.get("path") if isinstance(item, dict) else None
        for item in recorded_files
    ]
    if recorded_file_paths != expected_file_paths:
        raise ManifestError("manifest file scope mismatch")
    if recorded_excluded != expected_excluded:
        raise ManifestError("manifest exclusion scope mismatch")
    expected_digests = {
        item["path"]: item["sha256"]
        for item in expected_files
    }
    for item in recorded_files:
        if set(item) != {"path", "sha256"}:
            raise ManifestError("manifest file entry invalid")
        if item["sha256"] != expected_digests[item["path"]]:
            raise ManifestError(f"digest mismatch: {item['path']}")


def main(arguments: list[str]) -> int:
    if len(arguments) != 4 or arguments[1] not in {"generate", "verify"}:
        print(
            "usage: release-manifest.py generate|verify APP MANIFEST",
            file=sys.stderr,
        )
        return 64
    command, app_text, manifest_text = arguments[1:]
    app = Path(app_text)
    manifest = Path(manifest_text)
    try:
        if command == "generate":
            generate(app, manifest)
        else:
            verify(app, manifest)
    except ManifestError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
