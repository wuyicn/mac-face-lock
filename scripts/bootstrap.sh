#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "需要 Python 3.9 或更高版本。" >&2
  echo "请先运行: brew install python" >&2
  echo "也可指定可执行文件后重试: PYTHON_BIN=/path/to/python3 scripts/bootstrap.sh" >&2
  exit 1
fi

"$PYTHON_BIN" -m venv .venv
"$ROOT_DIR/.venv/bin/python" -m pip install --upgrade pip
"$ROOT_DIR/.venv/bin/python" -m pip install -r requirements-lock.txt

echo "依赖已安装到 $ROOT_DIR/.venv"
