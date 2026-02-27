#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/constants.sh
source "$SCRIPT_DIR/lib/constants.sh"

usage() {
  cat >&2 <<EOF
usage: notify.sh --message <text> [--slack-channel <id>] [--whatsapp <number>] [--all]

  --message         message text to send
  --slack-channel   slack channel id (default: \$SWARM_SLACK_CHANNEL)
  --whatsapp        whatsapp number (default: \$SWARM_WHATSAPP_TARGET)
  --all             send to all configured channels
EOF
  exit 1
}

# --- parse args ---

MESSAGE="" SEND_SLACK="" SEND_WHATSAPP="" SEND_ALL=""
SLACK_TARGET="${SLACK_CHANNEL:-}"
WHATSAPP_NUM="${WHATSAPP_TARGET:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message)        MESSAGE="$2"; shift 2 ;;
    --slack-channel)  SLACK_TARGET="$2"; SEND_SLACK=1; shift 2 ;;
    --whatsapp)       WHATSAPP_NUM="$2"; SEND_WHATSAPP=1; shift 2 ;;
    --all)            SEND_ALL=1; shift ;;
    *)                usage ;;
  esac
done

[[ -z "$MESSAGE" ]] && usage

# if --all, enable both channels where configured
if [[ -n "$SEND_ALL" ]]; then
  [[ -n "$SLACK_TARGET" ]] && SEND_SLACK=1
  [[ -n "$WHATSAPP_NUM" ]] && SEND_WHATSAPP=1
fi

# if no explicit channel selected, default to slack if configured
if [[ -z "$SEND_SLACK" && -z "$SEND_WHATSAPP" ]]; then
  if [[ -n "$SLACK_TARGET" ]]; then
    SEND_SLACK=1
  else
    echo "WARNING: no notification channel configured" >&2
    echo "$MESSAGE" >&2
    exit 0
  fi
fi

# --- send notifications ---

FAILED=0

if [[ -n "$SEND_SLACK" && -n "$SLACK_TARGET" ]]; then
  echo "sending slack notification..."
  if ! openclaw message send --channel slack --target "$SLACK_TARGET" --message "$MESSAGE" 2>/dev/null; then
    echo "WARNING: slack notification failed" >&2
    FAILED=1
  fi
fi

if [[ -n "$SEND_WHATSAPP" && -n "$WHATSAPP_NUM" ]]; then
  echo "sending whatsapp notification..."
  if ! openclaw message send --channel whatsapp --target "$WHATSAPP_NUM" --message "$MESSAGE" 2>/dev/null; then
    echo "WARNING: whatsapp notification failed" >&2
    FAILED=1
  fi
fi

if [[ "$FAILED" -eq 1 ]]; then
  echo "fallback: printing message to stderr" >&2
  echo "$MESSAGE" >&2
fi
