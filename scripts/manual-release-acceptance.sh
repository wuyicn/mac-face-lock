#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_ZIP="$ROOT_DIR/dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip"
DEFAULT_CHECKSUM="$DEFAULT_ZIP.sha256"

print_checklist() {
  cat <<'CHECKLIST'
人工验收清单（本脚本不会创建账户、修改隐私权限或启动应用）

[ ] PENDING — 在新建的普通测试账户中验收；该账户未安装 Codex、Python、Xcode，也没有源码仓库。
[ ] PENDING — 仅使用 Finder 解压发行包，把 Mac Face Lock.app 拖入“应用程序”。
[ ] PENDING — 首次启动使用 Finder 右键“打开”，没有关闭系统安全检查。
[ ] PENDING — 首次设置能打开摄像头权限页面，并能识别授权、拒绝和返回后的状态变化。
[ ] PENDING — “录入本人”要求完成正脸、左转、右转、轻微低头和轻微抬头；失败或取消不会留下不完整模板。
[ ] PENDING — “权限确认”显示统一 Mac Face Lock 应用身份的摄像头、输入监控、辅助功能和后台服务状态；缺少权限时可进入系统设置修复。
[ ] PENDING — 所有门槛通过前不能开启保护；通过后可明确开启。
[ ] PENDING — 退出并重新登录测试账户后，后台服务恢复运行，应用仍能显示正确状态。
[ ] PENDING — 撤销并恢复一个必需权限后，应用进入安全恢复状态，并能通过界面修复。
[ ] PENDING — “重新安装服务”可修复后台服务，且本人模板和设置仍保留。
[ ] PENDING — “卸载后台服务并保留数据”成功后服务停止；应用数据仍保留，再把应用移到废纸篓。
[ ] PENDING — 若测试机存在旧源码数据，发行版未读取或更改未明确确认范围之外的数据。

每项必须由测试人员填写 PASS / FAIL、macOS 版本、测试账户类型和简短证据。
CHECKLIST
}

if [[ "${1:-}" == "--print-only" ]]; then
  print_checklist
  exit 0
fi

ZIP="${1:-$DEFAULT_ZIP}"
CHECKSUM="${2:-$DEFAULT_CHECKSUM}"
if [[ ! -f "$ZIP" || ! -f "$CHECKSUM" ]]; then
  echo "发行 ZIP 或校验文件不存在。" >&2
  exit 1
fi

ZIP_DIR="$(cd "$(dirname "$ZIP")" && pwd)"
CHECKSUM_DIR="$(cd "$(dirname "$CHECKSUM")" && pwd)"
if [[ "$ZIP_DIR" != "$CHECKSUM_DIR" ]] \
  || [[ "$(basename "$CHECKSUM")" != "$(basename "$ZIP").sha256" ]]; then
  echo "ZIP 与校验文件必须位于同一目录并使用匹配文件名。" >&2
  exit 1
fi

(
  cd "$ZIP_DIR"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ditto -x -k "$ZIP" "$WORK_DIR"
APP="$WORK_DIR/Mac Face Lock.app"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

PYTHON="$ROOT_DIR/.build/runtime-python311/bin/python"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3)"
fi
"$PYTHON" "$ROOT_DIR/scripts/release-manifest.py" verify \
  "$APP" "$APP/Contents/Resources/BuildManifest.json"

echo
echo "自动预检：PASS"
echo "发行包：$(basename "$ZIP")"
echo "SHA-256：$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "版本：$(plutil -extract CFBundleShortVersionString raw \
  "$APP/Contents/Info.plist")"
echo
print_checklist
