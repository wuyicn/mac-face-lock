#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
echo "通过 Terminal 启动 mac-face-lock-agent。"
echo "当前按 config/config.json 中的模式运行。"
echo "按 Ctrl+C 可停止。"
echo
scripts/run-agent.sh
