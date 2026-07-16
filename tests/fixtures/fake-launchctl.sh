#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${FAKE_LAUNCHCTL_STATE:?}"
LOG_FILE="${FAKE_LAUNCHCTL_LOG:?}"
COMMAND="${1:?}"
shift

label_from_target() {
  basename "${1:?}"
}

program_from_plist() {
  /usr/bin/python3 - "${1:?}" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle)["ProgramArguments"][0])
PY
}

case "$COMMAND" in
  print)
    LABEL="$(label_from_target "${1:?}")"
    echo "print $LABEL" >> "$LOG_FILE"
    [[ -f "$STATE_DIR/$LABEL.loaded" ]] || exit 113
    PROGRAM="$(<"$STATE_DIR/$LABEL.program")"
    if [[ "$LABEL" == "com.wuyi.mac-face-lock-status" && "$PROGRAM" == *"Mac Face Lock.app"* ]]; then
      case "${FAKE_UI_MODE:-running}" in
        crash)
          printf 'state = exited\nprogram = %s\n' "$PROGRAM"
          exit 0
          ;;
        wrong_program)
          printf 'state = running\nprogram = %s\npid = 2202\n' "$STATE_DIR/wrong-ui"
          exit 0
          ;;
        pid_change)
          COUNT_FILE="$STATE_DIR/ui-print-count"
          COUNT=0
          [[ ! -f "$COUNT_FILE" ]] || COUNT="$(<"$COUNT_FILE")"
          COUNT=$((COUNT + 1))
          printf '%s\n' "$COUNT" > "$COUNT_FILE"
          printf 'state = running\nprogram = %s\npid = %s\n' "$PROGRAM" "$((2201 + COUNT))"
          exit 0
          ;;
      esac
    fi
    printf 'state = running\nprogram = %s\npid = %s\n' "$PROGRAM" "$([[ "$LABEL" == *status ]] && echo 2202 || echo 1101)"
    ;;
  bootout)
    LABEL="$(label_from_target "${1:?}")"
    echo "bootout $LABEL" >> "$LOG_FILE"
    rm -f "$STATE_DIR/$LABEL.loaded"
    ;;
  bootstrap)
    PLIST="${2:?}"
    LABEL="$(basename "$PLIST" .plist)"
    PROGRAM="$(program_from_plist "$PLIST")"
    echo "bootstrap $PLIST $PROGRAM" >> "$LOG_FILE"
    if [[ "$LABEL" == "com.wuyi.mac-face-lock-agent" && "${FAKE_AGENT_MODE:-running}" == "fail_load" && "$PROGRAM" == *"Mac Face Lock Agent.app"* ]]; then
      exit 5
    fi
    printf '%s\n' "$PROGRAM" > "$STATE_DIR/$LABEL.program"
    touch "$STATE_DIR/$LABEL.loaded"
    ;;
  enable|kickstart)
    if [[ "$COMMAND" == "kickstart" && "${1:-}" == "-k" ]]; then
      shift
    fi
    LABEL="$(label_from_target "${1:?}")"
    echo "$COMMAND $LABEL" >> "$LOG_FILE"
    ;;
  *)
    echo "unexpected $COMMAND $*" >> "$LOG_FILE"
    exit 64
    ;;
esac
