#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_CODE="$ROOT_DIR/scripts/sign-code.sh"
UV_REQUIRED_VERSION="0.11.13"
UV_BIN="${UV_BIN:-$(command -v uv || true)}"
BUILD_DIR="$ROOT_DIR/.build"
VENV_DIR="$BUILD_DIR/runtime-python311"
DIST_DIR="$ROOT_DIR/dist/runtime"
mkdir -p "$BUILD_DIR"
STAGED_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/mac-face-lock-runtime-build.XXXXXX")"
cleanup() {
  rm -rf "$STAGED_SOURCE"
}
trap cleanup EXIT

if [[ -z "$UV_BIN" || ! -x "$UV_BIN" ]]; then
  echo "uv $UV_REQUIRED_VERSION is required; install the pinned uv prerequisite." >&2
  exit 69
fi
ACTUAL_UV_VERSION="$("$UV_BIN" --version | awk '{ print $2 }')"
if [[ "$ACTUAL_UV_VERSION" != "$UV_REQUIRED_VERSION" ]]; then
  echo "uv $UV_REQUIRED_VERSION is required; found $ACTUAL_UV_VERSION." >&2
  exit 69
fi

export PYTHONHASHSEED=0
export MACOSX_DEPLOYMENT_TARGET=12.0
export UV_CACHE_DIR="${UV_CACHE_DIR:-$BUILD_DIR/uv-cache}"
TCC_BUNDLE_IDENTIFIER="com.wuyi.mac-face-lock.app"

"$UV_BIN" python install 3.11
"$UV_BIN" venv --clear --python 3.11 "$VENV_DIR"
"$UV_BIN" pip install --python "$VENV_DIR/bin/python" \
  -r "$ROOT_DIR/requirements-lock.txt" \
  -r "$ROOT_DIR/requirements-build-lock.txt"

"$VENV_DIR/bin/python" - <<'PY'
import platform
import sys

assert sys.version_info[:2] == (3, 11), sys.version
assert platform.machine() == "arm64", platform.machine()
PY

rm -rf "$DIST_DIR" "$BUILD_DIR/pyinstaller"
mkdir -p "$DIST_DIR" "$BUILD_DIR/pyinstaller"
mkdir -p "$STAGED_SOURCE/packaging"
cp "$ROOT_DIR"/*.py "$STAGED_SOURCE/"
cp "$ROOT_DIR/packaging/mac-face-lock-runtime.spec" "$STAGED_SOURCE/packaging/"
"$VENV_DIR/bin/pyinstaller" \
  --clean \
  --noconfirm \
  --distpath "$DIST_DIR" \
  --workpath "$BUILD_DIR/pyinstaller" \
  "$STAGED_SOURCE/packaging/mac-face-lock-runtime.spec"

test -x "$DIST_DIR/MacFaceLockRuntime/MacFaceLockRuntime"
RUNTIME_EXECUTABLE="$DIST_DIR/MacFaceLockRuntime/MacFaceLockRuntime"
PATCHED_EXECUTABLE="$BUILD_DIR/MacFaceLockRuntime.minos12"
xcrun vtool \
  -set-build-version macos 12.0 15.5 \
  -replace \
  -output "$PATCHED_EXECUTABLE" \
  "$RUNTIME_EXECUTABLE"
chmod +x "$PATCHED_EXECUTABLE"
mv "$PATCHED_EXECUTABLE" "$RUNTIME_EXECUTABLE"
"$SIGN_CODE" \
  --identifier "$TCC_BUNDLE_IDENTIFIER" \
  "$RUNTIME_EXECUTABLE" >/dev/null
xcrun vtool -show-build "$RUNTIME_EXECUTABLE" |
  awk '$1 == "minos" { found = 1; if ($2 != "12.0") exit 1 } END { exit !found }'
echo "$DIST_DIR/MacFaceLockRuntime"
