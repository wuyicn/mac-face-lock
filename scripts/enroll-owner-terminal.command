#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
echo "准备通过 Terminal 录入本人脸部特征。"
echo "如果系统弹出摄像头权限请求，请选择允许。"
echo
scripts/enroll-owner.sh
echo
echo "录入完成，可以关闭此窗口。"
read -r -p "按回车退出..."
