#!/usr/bin/env bash
set -euo pipefail

LABEL="com.wuyi.mac-face-lock-agent"
STATUS_LABEL="com.wuyi.mac-face-lock-status"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATUS_PLIST_DST="$HOME/Library/LaunchAgents/$STATUS_LABEL.plist"
UID_VALUE="$(id -u)"

if launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID_VALUE/$LABEL" || true
fi
if launchctl print "gui/$UID_VALUE/$STATUS_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID_VALUE/$STATUS_LABEL" || true
fi

rm -f "$PLIST_DST"
rm -f "$STATUS_PLIST_DST"
echo "已卸载 $LABEL"
echo "已卸载融合界面 $STATUS_LABEL"
echo "本地配置、活动记录、证据与本人脸部特征均已保留"
