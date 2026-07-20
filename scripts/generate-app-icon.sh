#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (( $# > 1 )); then
  echo "usage: generate-app-icon.sh [OUTPUT.icns]" >&2
  exit 64
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-face-lock-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

MASTER="$WORK_DIR/AppIcon-1024.png"
ICONSET="$WORK_DIR/AppIcon.iconset"
OUTPUT="${1:-$ROOT_DIR/src/app/AppIcon.icns}"
mkdir -p "$ICONSET"

xcrun swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$MASTER"

render() {
  local pixels="$1"
  local name="$2"
  sips -z "$pixels" "$pixels" "$MASTER" \
    --out "$ICONSET/$name" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns -o "$OUTPUT" "$ICONSET"
echo "$OUTPUT"
