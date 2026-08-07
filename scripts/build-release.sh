#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_CODE="$ROOT_DIR/scripts/sign-code.sh"
VERSION="0.2.0-beta"
RELEASE_DIR="$ROOT_DIR/dist/release"
if [[ "$(git -C "$ROOT_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
  echo "release build must run from a Git worktree" >&2
  exit 1
fi
DIRTY_STATE="$(cd "$ROOT_DIR" && git status --porcelain=v1 --untracked-files=all)"
if [[ -n "$DIRTY_STATE" ]]; then
  echo "release build requires a clean Git worktree" >&2
  printf '%s\n' "$DIRTY_STATE" >&2
  exit 1
fi
SOURCE_COMMIT="$(cd "$ROOT_DIR" && git rev-parse HEAD)"
if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "release source commit must be a lowercase 40-character SHA" >&2
  exit 1
fi
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
TCC_BUNDLE_IDENTIFIER="com.wuyi.mac-face-lock.app"

rm -rf "$RELEASE_DIR"
mkdir -p "$STAGING_DIR" "$RELEASE_DIR"

"$ROOT_DIR/scripts/build-runtime.sh"
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
  "$SIGN_CODE" "$code_path" >/dev/null 2>&1
done < <(
  find "$RESOURCES/runtime/MacFaceLockRuntime" -type f -print0 |
    xargs -0 file |
    awk -F: '/Mach-O/ { print $1 }' |
    sort -r
)

"$SIGN_CODE" \
  --identifier "$TCC_BUNDLE_IDENTIFIER" \
  "$RESOURCES/runtime/MacFaceLockRuntime/MacFaceLockRuntime" >/dev/null

if [[ -e "$APP/Contents/Library/LoginItems/Mac Face Lock Agent.app" ]]; then
  echo "release app must not embed Mac Face Lock Agent.app" >&2
  exit 1
fi
if find "$APP" -name MacFaceLockAgent -print -quit | grep -q .; then
  echo "release app must not contain MacFaceLockAgent" >&2
  exit 1
fi
if LC_ALL=C grep -a -r -q "com.wuyi.mac-face-lock-agent.app" "$APP"; then
  echo "release app must not contain the old Agent bundle identifier" >&2
  exit 1
fi
test -x "$RESOURCES/runtime/MacFaceLockRuntime/MacFaceLockRuntime"

MANIFEST="$RESOURCES/BuildManifest.json"
# Establish every signature path before recording the exact exclusion set.
"$SIGN_CODE" --deep \
  --identifier "$TCC_BUNDLE_IDENTIFIER" \
  "$APP" >/dev/null
"$ROOT_DIR/.build/runtime-python311/bin/python" \
  "$ROOT_DIR/scripts/release-manifest.py" generate \
  "$APP" "$MANIFEST" "$SOURCE_COMMIT"
"$SIGN_CODE" --deep \
  --identifier "$TCC_BUNDLE_IDENTIFIER" \
  "$APP" >/dev/null
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
if [[ -e "$EXTRACTED/Mac Face Lock.app/Contents/Library/LoginItems/Mac Face Lock Agent.app" ]]; then
  echo "release archive must not embed Mac Face Lock Agent.app" >&2
  exit 1
fi
if find "$EXTRACTED/Mac Face Lock.app" -name MacFaceLockAgent -print -quit | grep -q .; then
  echo "release archive must not contain MacFaceLockAgent" >&2
  exit 1
fi
if LC_ALL=C grep -a -r -q "com.wuyi.mac-face-lock-agent.app" \
  "$EXTRACTED/Mac Face Lock.app"; then
  echo "release archive must not contain the old Agent bundle identifier" >&2
  exit 1
fi
MAC_FACE_LOCK_RELEASE_APP="$EXTRACTED/Mac Face Lock.app" \
  "$ROOT_DIR/.build/runtime-python311/bin/python" -m unittest \
  tests.test_release_bundle.ExtractedReleaseBundleTests -v

echo "$ZIP"
echo "$CHECKSUM"
