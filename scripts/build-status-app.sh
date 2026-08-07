#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_CODE="$ROOT_DIR/scripts/sign-code.sh"
APP_DIR="$ROOT_DIR/dist/Mac Face Lock.app"
BUILD_DIR="$ROOT_DIR/dist/.Mac Face Lock.app.building"
PREVIOUS_DIR="$ROOT_DIR/dist/.Mac Face Lock.app.previous"
SWAP_HELPER="$ROOT_DIR/scripts/atomic-swap.py"
CONTENTS_DIR="$BUILD_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/MacFaceLock"
GENERATION_FILE="Contents/Resources/BuildGeneration"
RUNTIME_SOURCE="$ROOT_DIR/dist/runtime/MacFaceLockRuntime"
RUNTIME_EXECUTABLE="$RUNTIME_SOURCE/MacFaceLockRuntime"
BUNDLED_RUNTIME_EXECUTABLE="Contents/Resources/runtime/MacFaceLockRuntime/MacFaceLockRuntime"
RELEASE_LAUNCHD_DIR="$RESOURCES_DIR/launchd"
TCC_BUNDLE_IDENTIFIER="com.wuyi.mac-face-lock.app"

bundle_is_valid() {
  local bundle="$1"
  [[ -d "$bundle" ]] || return 1
  [[ -x "$bundle/Contents/MacOS/MacFaceLock" ]] || return 1
  [[ -x "$bundle/$BUNDLED_RUNTIME_EXECUTABLE" ]] || return 1
  [[ -f "$bundle/Contents/Resources/launchd/com.wuyi.mac-face-lock-release.plist" ]] || return 1
  plutil -lint "$bundle/Contents/Info.plist" >/dev/null 2>&1 || return 1
  plutil -lint \
    "$bundle/Contents/Resources/launchd/com.wuyi.mac-face-lock-release.plist" \
    >/dev/null 2>&1 || return 1
  codesign --verify --deep --strict "$bundle" >/dev/null 2>&1 || return 1
}

bundle_generation() {
  local bundle="$1"
  local value="0"
  if [[ -f "$bundle/$GENERATION_FILE" ]]; then
    value="$(<"$bundle/$GENERATION_FILE")"
  fi
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

recover_pair() {
  local recovery="$1"
  local discard_invalid_without_current="${2:-0}"
  if [[ ! -e "$recovery" ]]; then
    return
  fi

  if [[ ! -e "$APP_DIR" ]]; then
    if bundle_is_valid "$recovery"; then
      "$SWAP_HELPER" "$recovery" "$APP_DIR"
      return
    fi
    if [[ "$discard_invalid_without_current" == "1" ]]; then
      rm -rf "$recovery"
      return
    fi
    echo "恢复产物无效且当前应用不存在: $recovery" >&2
    return 1
  fi

  if bundle_is_valid "$APP_DIR"; then
    if bundle_is_valid "$recovery"; then
      local app_generation recovery_generation
      app_generation="$(bundle_generation "$APP_DIR")"
      recovery_generation="$(bundle_generation "$recovery")"
      if (( recovery_generation > app_generation )); then
        "$SWAP_HELPER" "$recovery" "$APP_DIR"
        bundle_is_valid "$APP_DIR" || return 1
      fi
    fi
    rm -rf "$recovery"
    return
  fi

  if bundle_is_valid "$recovery"; then
    "$SWAP_HELPER" "$recovery" "$APP_DIR"
    bundle_is_valid "$APP_DIR" || return 1
    rm -rf "$recovery"
    return
  fi

  echo "当前应用与恢复产物均无效，已保留现场" >&2
  return 1
}

mkdir -p "$ROOT_DIR/dist"
recover_pair "$PREVIOUS_DIR"
recover_pair "$BUILD_DIR" 1

if [[ ! -x "$RUNTIME_EXECUTABLE" ]]; then
  echo "缺少已构建的运行时: $RUNTIME_EXECUTABLE" >&2
  exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/runtime" "$RELEASE_LAUNCHD_DIR"
cp "$ROOT_DIR/src/app/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/src/app/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp -R "$RUNTIME_SOURCE" "$RESOURCES_DIR/runtime/MacFaceLockRuntime"
cp "$ROOT_DIR/launchd/com.wuyi.mac-face-lock-release.plist" \
  "$RELEASE_LAUNCHD_DIR/com.wuyi.mac-face-lock-release.plist"
CURRENT_GENERATION="$(bundle_generation "$APP_DIR")"
printf '%s\n' "$((CURRENT_GENERATION + 1))" > "$BUILD_DIR/$GENERATION_FILE"
SOURCE_FILES=("$ROOT_DIR"/src/app/*.swift)

xcrun swiftc "${SOURCE_FILES[@]}" \
  -parse-as-library \
  -target arm64-apple-macosx12.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -o "$EXECUTABLE"
chmod +x "$EXECUTABLE"
"$SIGN_CODE" --deep \
  --identifier "$TCC_BUNDLE_IDENTIFIER" \
  "$BUILD_DIR" >/dev/null
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
plutil -lint \
  "$RELEASE_LAUNCHD_DIR/com.wuyi.mac-face-lock-release.plist" >/dev/null
codesign --verify --deep --strict "$BUILD_DIR"

"$SWAP_HELPER" "$BUILD_DIR" "$APP_DIR"
bundle_is_valid "$APP_DIR"
rm -rf "$BUILD_DIR"
touch "$APP_DIR"
echo "$APP_DIR"
