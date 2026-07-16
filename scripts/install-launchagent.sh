#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LABEL="com.wuyi.mac-face-lock-agent"
STATUS_LABEL="com.wuyi.mac-face-lock-status"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATUS_PLIST_DST="$HOME/Library/LaunchAgents/$STATUS_LABEL.plist"
UID_VALUE="$(id -u)"
UNIFIED_APP="$ROOT_DIR/dist/Mac Face Lock.app"
UNIFIED_EXECUTABLE="$UNIFIED_APP/Contents/MacOS/MacFaceLock"
OLD_STATUS_APP="$ROOT_DIR/dist/Mac Face Lock Status.app"
AGENT_APP="$ROOT_DIR/dist/Mac Face Lock Agent.app"
AGENT_EXECUTABLE="$AGENT_APP/Contents/MacOS/MacFaceLockAgent"
BACKUP_DIR=""
MIGRATION_ACTIVE=0
MIGRATION_COMPLETE=0

load_service() {
  local label="$1"
  local plist="$2"

  if launchctl print "gui/$UID_VALUE/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID_VALUE/$label" || true
  fi

  if ! launchctl bootstrap "gui/$UID_VALUE" "$plist" 2>/dev/null; then
    sleep 1
    launchctl bootout "gui/$UID_VALUE/$label" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID_VALUE" "$plist"
  fi
  launchctl enable "gui/$UID_VALUE/$label"
  launchctl kickstart -k "gui/$UID_VALUE/$label"
}

verify_running_service() {
  local label="$1"
  local expected_program="$2"
  local required_polls="${3:-3}"
  local stable_pid=""
  local poll output state program pid

  for ((poll = 1; poll <= required_polls; poll++)); do
    output="$(launchctl print "gui/$UID_VALUE/$label")" || return 1
    state="$(awk -F ' = ' '/^[[:space:]]*state = / { print $2; exit }' <<<"$output")"
    program="$(awk -F ' = ' '/^[[:space:]]*program = / { print $2; exit }' <<<"$output")"
    pid="$(awk -F ' = ' '/^[[:space:]]*pid = / { print $2; exit }' <<<"$output")"
    [[ "$state" == "running" ]] || return 1
    [[ "$program" == "$expected_program" ]] || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ -z "$stable_pid" ]]; then
      stable_pid="$pid"
    elif [[ "$pid" != "$stable_pid" ]]; then
      return 1
    fi
    if (( poll < required_polls )); then
      sleep 1
    fi
  done
}

backup_plist() {
  local source="$1"
  local name="$2"
  if [[ -f "$source" ]]; then
    cp "$source" "$BACKUP_DIR/$name.plist"
    printf '1\n' > "$BACKUP_DIR/$name.plist-present"
  else
    printf '0\n' > "$BACKUP_DIR/$name.plist-present"
  fi
}

backup_job() {
  local label="$1"
  local name="$2"
  if launchctl print "gui/$UID_VALUE/$label" > "$BACKUP_DIR/$name.job" 2>&1; then
    printf '1\n' > "$BACKUP_DIR/$name.loaded"
  else
    printf '0\n' > "$BACKUP_DIR/$name.loaded"
  fi
}

backup_bundle() {
  local source="$1"
  local name="$2"
  if [[ -e "$source" || -L "$source" ]]; then
    cp -a "$source" "$BACKUP_DIR/$name.bundle"
    printf '1\n' > "$BACKUP_DIR/$name.bundle-present"
  else
    printf '0\n' > "$BACKUP_DIR/$name.bundle-present"
  fi
}

restore_plist() {
  local destination="$1"
  local name="$2"

  if [[ "$(<"$BACKUP_DIR/$name.plist-present")" == "1" ]]; then
    cp "$BACKUP_DIR/$name.plist" "$destination"
  else
    rm -f "$destination"
  fi
}

restore_bundle() {
  local destination="$1"
  local name="$2"

  rm -rf "$destination"
  if [[ "$(<"$BACKUP_DIR/$name.bundle-present")" == "1" ]]; then
    cp -a "$BACKUP_DIR/$name.bundle" "$destination"
  fi
}

restore_job() {
  local label="$1"
  local destination="$2"
  local name="$3"

  if [[ "$(<"$BACKUP_DIR/$name.loaded")" == "1" && -f "$destination" ]]; then
    launchctl bootstrap "gui/$UID_VALUE" "$destination"
    launchctl enable "gui/$UID_VALUE/$label"
    launchctl kickstart -k "gui/$UID_VALUE/$label"
  fi
}

rollback_migration() {
  set +e
  launchctl bootout "gui/$UID_VALUE/$STATUS_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  restore_plist "$STATUS_PLIST_DST" "ui"
  restore_plist "$PLIST_DST" "agent"
  restore_bundle "$OLD_STATUS_APP" "legacy-ui"
  restore_bundle "$UNIFIED_APP" "unified-ui"
  restore_bundle "$AGENT_APP" "agent-app"
  restore_job "$LABEL" "$PLIST_DST" "agent"
  restore_job "$STATUS_LABEL" "$STATUS_PLIST_DST" "ui"
  set -e
}

handle_exit() {
  local result=$?
  trap - EXIT
  if (( result != 0 && MIGRATION_ACTIVE == 1 && MIGRATION_COMPLETE == 0 )); then
    echo "安装未完成，正在恢复安装前的应用与 LaunchAgent" >&2
    rollback_migration
  fi
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
  fi
  exit "$result"
}

GIT_DIR="$(cd "$ROOT_DIR" && cd "$(git rev-parse --git-dir)" && pwd -P)"
GIT_COMMON="$(cd "$ROOT_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
if [[ "$GIT_DIR" != "$GIT_COMMON" && "${MAC_FACE_LOCK_TEST_MODE:-0}" != "1" ]]; then
  echo "为避免安装临时工作树产物，请在主仓库目录运行安装脚本" >&2
  exit 1
fi

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  echo "未找到虚拟环境，请先运行 scripts/bootstrap.sh" >&2
  exit 1
fi

if [[ ! -f "$ROOT_DIR/data/owner_face.npy" ]]; then
  echo "未找到本人脸部特征，请先运行 scripts/enroll-owner.sh" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$ROOT_DIR/logs" "$ROOT_DIR/data"
BACKUP_DIR="$(mktemp -d "$ROOT_DIR/logs/launch-migration.XXXXXX")"
trap handle_exit EXIT
backup_plist "$PLIST_DST" "agent"
backup_plist "$STATUS_PLIST_DST" "ui"
backup_job "$LABEL" "agent"
backup_job "$STATUS_LABEL" "ui"
backup_bundle "$AGENT_APP" "agent-app"
backup_bundle "$UNIFIED_APP" "unified-ui"
backup_bundle "$OLD_STATUS_APP" "legacy-ui"
MIGRATION_ACTIVE=1

"$ROOT_DIR/scripts/build-app.sh" >/dev/null
"$ROOT_DIR/scripts/build-status-app.sh" >/dev/null

if [[ ! -x "$UNIFIED_EXECUTABLE" ]]; then
  echo "融合界面构建产物缺少可执行文件: $UNIFIED_EXECUTABLE" >&2
  exit 1
fi
plutil -lint "$UNIFIED_APP/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$UNIFIED_APP"

GENERATED_DIR="$BACKUP_DIR/generated"
"$ROOT_DIR/.venv/bin/python" "$ROOT_DIR/scripts/render-launchagents.py" \
  --project-dir "$ROOT_DIR" \
  --output-dir "$GENERATED_DIR" >/dev/null
GENERATED_PLIST="$GENERATED_DIR/$LABEL.plist"
GENERATED_STATUS_PLIST="$GENERATED_DIR/$STATUS_LABEL.plist"
plutil -lint "$GENERATED_PLIST" >/dev/null
plutil -lint "$GENERATED_STATUS_PLIST" >/dev/null

cp "$GENERATED_PLIST" "$PLIST_DST"
cp "$GENERATED_STATUS_PLIST" "$STATUS_PLIST_DST"

load_service "$LABEL" "$PLIST_DST"
load_service "$STATUS_LABEL" "$STATUS_PLIST_DST"
verify_running_service "$LABEL" "$AGENT_EXECUTABLE" 3
verify_running_service "$STATUS_LABEL" "$UNIFIED_EXECUTABLE" 3

rm -rf "$OLD_STATUS_APP"
MIGRATION_COMPLETE=1

echo "已安装并启动 $LABEL"
echo "已安装并启动融合界面 $STATUS_LABEL"
