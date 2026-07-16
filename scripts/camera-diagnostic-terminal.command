#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
echo "准备抓取一张摄像头诊断图。"
echo "请保持你刚才觉得识别不到的位置，脸不要动。"
echo
scripts/camera-diagnostic.sh
echo
read -r -p "按回车退出..."
