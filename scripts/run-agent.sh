#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$ROOT_DIR/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
  echo "未找到虚拟环境，请先运行 scripts/bootstrap.sh" >&2
  exit 1
fi

cd "$ROOT_DIR"
exec "$PYTHON" -u agent.py
