#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.wuyi.mac-face-lock-agent"
STATUS_LABEL="com.wuyi.mac-face-lock-status"
UID_VALUE="$(id -u)"

echo "项目: $ROOT_DIR"
echo "服务: $LABEL"
echo

if launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1; then
  echo "LaunchAgent: 已加载"
  launchctl print "gui/$UID_VALUE/$LABEL" | awk '
    /inherited environment = / { skip=1; next }
    /default environment = / { skip=1; next }
    /environment = / { skip=1; next }
    skip && /^	}/ { skip=0; next }
    !skip { print }
  ' | sed -n '1,45p'
else
  echo "LaunchAgent: 未加载"
fi

echo
echo "融合界面: $STATUS_LABEL"
if launchctl print "gui/$UID_VALUE/$STATUS_LABEL" >/dev/null 2>&1; then
  echo "融合界面: 已加载"
  launchctl print "gui/$UID_VALUE/$STATUS_LABEL" | awk '
    /inherited environment = / { skip=1; next }
    /default environment = / { skip=1; next }
    /environment = / { skip=1; next }
    skip && /^	}/ { skip=0; next }
    !skip { print }
  ' | sed -n '1,35p'
else
  echo "融合界面: 未加载"
fi

echo
if [[ -f "$ROOT_DIR/logs/agent.pid" ]]; then
  PID="$(cat "$ROOT_DIR/logs/agent.pid")"
  if ps -p "$PID" >/dev/null 2>&1; then
    echo "进程: 运行中 pid=$PID"
  else
    echo "进程: PID 文件存在但进程不在 pid=$PID"
  fi
else
  echo "进程: 未发现 PID 文件"
fi

echo
if [[ -f "$ROOT_DIR/data/state.json" ]]; then
  echo "状态:"
  cat "$ROOT_DIR/data/state.json"
else
  echo "状态: 暂无 state.json"
fi

echo
if [[ -f "$ROOT_DIR/logs/agent.log" ]]; then
  echo "最近日志:"
  tail -n 20 "$ROOT_DIR/logs/agent.log"
else
  echo "最近日志: 暂无 agent.log"
fi
