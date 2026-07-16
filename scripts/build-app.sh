#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Mac Face Lock Agent.app"
BUILD_DIR="$ROOT_DIR/dist/.Mac Face Lock Agent.app.building"
SWAP_HELPER="$ROOT_DIR/scripts/atomic-swap.py"
CONTENTS_DIR="$BUILD_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/MacFaceLockAgent"

mkdir -p "$ROOT_DIR/dist"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Mac Face Lock Agent</string>
  <key>CFBundleDisplayName</key>
  <string>Mac Face Lock Agent</string>
  <key>CFBundleIdentifier</key>
  <string>com.wuyi.mac-face-lock-agent.app</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleExecutable</key>
  <string>MacFaceLockAgent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>用于在保护态下拍摄当前使用人并进行本地本人识别。</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>用于触发 macOS 锁屏相关系统操作。</string>
</dict>
</plist>
PLIST

xcrun swiftc -parse-as-library \
  -target arm64-apple-macosx12.0 \
  "$ROOT_DIR/src/agent-launcher/main.swift" \
  -o "$EXECUTABLE"
codesign --sign - --force --deep "$BUILD_DIR" >/dev/null
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
codesign --verify --deep --strict "$BUILD_DIR"

"$SWAP_HELPER" "$BUILD_DIR" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
rm -rf "$BUILD_DIR"
touch "$APP_DIR"
echo "$APP_DIR"
