#!/usr/bin/env bash
set -euo pipefail

SIGNING_IDENTITY="${MAC_FACE_LOCK_SIGNING_IDENTITY:--}"
DEEP_SIGNING=0
IDENTIFIER=""
TARGET=""

while (( $# > 0 )); do
  case "$1" in
    --deep)
      DEEP_SIGNING=1
      shift
      ;;
    --identifier)
      if (( $# < 2 )); then
        echo "--identifier requires a value" >&2
        exit 64
      fi
      IDENTIFIER="$2"
      shift 2
      ;;
    --)
      shift
      if (( $# != 1 )); then
        echo "usage: sign-code.sh [--deep] [--identifier ID] TARGET" >&2
        exit 64
      fi
      TARGET="$1"
      shift
      ;;
    -*)
      echo "unsupported signing option: $1" >&2
      exit 64
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        echo "usage: sign-code.sh [--deep] [--identifier ID] TARGET" >&2
        exit 64
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "usage: sign-code.sh [--deep] [--identifier ID] TARGET" >&2
  exit 64
fi

CODESIGN_ARGUMENTS=(--sign "$SIGNING_IDENTITY" --force)
if (( DEEP_SIGNING == 1 )); then
  CODESIGN_ARGUMENTS+=(--deep)
fi
if [[ -n "$IDENTIFIER" ]]; then
  CODESIGN_ARGUMENTS+=(-i "$IDENTIFIER")
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    CODESIGN_ARGUMENTS+=(
      "-r=designated => identifier \"$IDENTIFIER\""
    )
  fi
fi

codesign "${CODESIGN_ARGUMENTS[@]}" "$TARGET"
