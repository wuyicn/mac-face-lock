#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.2.0-beta"
RELEASE_DIR="$ROOT_DIR/dist/release"
STAGING_DIR="$ROOT_DIR/.build/release-staging"
APP="$STAGING_DIR/Mac Face Lock.app"
RESOURCES="$APP/Contents/Resources"
ZIP="$RELEASE_DIR/Mac-Face-Lock-$VERSION-arm64.zip"
CHECKSUM="$ZIP.sha256"

rm -rf "$STAGING_DIR" "$RELEASE_DIR"
mkdir -p "$STAGING_DIR" "$RELEASE_DIR"

"$ROOT_DIR/scripts/build-runtime.sh"
"$ROOT_DIR/scripts/build-app.sh" >/dev/null
"$ROOT_DIR/scripts/build-status-app.sh" >/dev/null
cp -R "$ROOT_DIR/dist/Mac Face Lock.app" "$APP"

rm -rf "$RESOURCES/runtime"
mkdir -p "$RESOURCES/runtime" "$RESOURCES/defaults"
mkdir -p "$RESOURCES/help"
cp -R \
  "$ROOT_DIR/dist/runtime/MacFaceLockRuntime" \
  "$RESOURCES/runtime/MacFaceLockRuntime"
cp "$ROOT_DIR/config/config.json" "$RESOURCES/defaults/config.json"
cp "$ROOT_DIR/LICENSE" "$RESOURCES/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/docs/legacy-install-resolution.md" \
  "$RESOURCES/help/legacy-install-resolution.md"

while IFS= read -r code_path; do
  codesign --sign - --force "$code_path" >/dev/null 2>&1
done < <(
  find "$RESOURCES/runtime/MacFaceLockRuntime" -type f -print0 |
    xargs -0 file |
    awk -F: '/Mach-O/ { print $1 }' |
    sort -r
)

codesign --sign - --force --deep \
  "$APP/Contents/Library/LoginItems/Mac Face Lock Agent.app" >/dev/null

MANIFEST="$RESOURCES/BuildManifest.json"
"$ROOT_DIR/.build/runtime-python311/bin/python" - "$APP" "$MANIFEST" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

app = Path(sys.argv[1])
manifest = Path(sys.argv[2])
files = []
for path in sorted(app.rglob("*")):
    if not path.is_file() or path.is_symlink() or path == manifest:
        continue
    files.append(
        {
            "path": path.relative_to(app).as_posix(),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
    )
manifest.write_text(
    json.dumps(
        {
            "schema_version": 1,
            "version": "0.2.0-beta",
            "architecture": "arm64",
            "minimum_macos": "12.0",
            "files": files,
        },
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
PY

codesign --sign - --force --deep "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$ZIP")" > "$(basename "$CHECKSUM")"
)
(
  cd "$RELEASE_DIR"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)

EXTRACTED="$ROOT_DIR/.build/release-extracted"
rm -rf "$EXTRACTED"
mkdir -p "$EXTRACTED"
ditto -x -k "$ZIP" "$EXTRACTED"
codesign --verify --deep --strict "$EXTRACTED/Mac Face Lock.app"
MAC_FACE_LOCK_RELEASE_APP="$EXTRACTED/Mac Face Lock.app" \
  "$ROOT_DIR/.build/runtime-python311/bin/python" -m unittest \
  tests.test_release_bundle.ExtractedReleaseBundleTests -v

echo "$ZIP"
echo "$CHECKSUM"
