#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.2.0-beta"
RELEASE_DIR="$ROOT_DIR/dist/release"
mkdir -p "$ROOT_DIR/.build"
BUILD_WORK_DIR="$(mktemp -d "$ROOT_DIR/.build/release.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_WORK_DIR"
}
trap cleanup EXIT
STAGING_DIR="$BUILD_WORK_DIR/staging"
APP="$STAGING_DIR/Mac Face Lock.app"
RESOURCES="$APP/Contents/Resources"
ZIP="$RELEASE_DIR/Mac-Face-Lock-$VERSION-arm64.zip"
CHECKSUM="$ZIP.sha256"

rm -rf "$RELEASE_DIR"
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
"$ROOT_DIR/.build/runtime-python311/bin/python" \
  "$ROOT_DIR/scripts/collect-release-licenses.py" \
  "$RESOURCES/licenses"

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
# Establish every signature path before recording the exact exclusion set.
codesign --sign - --force --deep "$APP" >/dev/null
"$ROOT_DIR/.build/runtime-python311/bin/python" \
  "$ROOT_DIR/scripts/release-manifest.py" generate "$APP" "$MANIFEST"
codesign --sign - --force --deep "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
"$ROOT_DIR/.build/runtime-python311/bin/python" \
  "$ROOT_DIR/scripts/release-manifest.py" verify "$APP" "$MANIFEST"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$ZIP")" > "$(basename "$CHECKSUM")"
)
(
  cd "$RELEASE_DIR"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)

EXTRACTED="$BUILD_WORK_DIR/extracted"
mkdir -p "$EXTRACTED"
ditto -x -k "$ZIP" "$EXTRACTED"
codesign --verify --deep --strict "$EXTRACTED/Mac Face Lock.app"
MAC_FACE_LOCK_RELEASE_APP="$EXTRACTED/Mac Face Lock.app" \
  "$ROOT_DIR/.build/runtime-python311/bin/python" -m unittest \
  tests.test_release_bundle.ExtractedReleaseBundleTests -v

echo "$ZIP"
echo "$CHECKSUM"
