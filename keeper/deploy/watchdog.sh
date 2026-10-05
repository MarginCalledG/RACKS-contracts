#!/usr/bin/env bash
# Outside watchdog for the RACKS keeper. Run from cron every 5 minutes.
#
# The bot warns on stderr, but a dead process warns about nothing — that is the whole point of
# checking from outside. Everything here is read-only.
#
#   */5 * * * * /opt/racks-keeper/deploy/watchdog.sh
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f ../.env ] && set -a && . ../.env && set +a

ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"          # Telegram/Slack/whatever; empty prints to stderr
alert() {
  echo "RACKS keeper: $*" >&2
  [ -n "$ALERT_WEBHOOK" ] && curl -s -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"RACKS keeper: $*\"}" "$ALERT_WEBHOOK" >/dev/null
}

# 1. is the unit up at all
systemctl is-active --quiet racks-keeper || alert "unit is not active ($(systemctl is-active racks-keeper))"

# 2. exit code 2 means the committed chain and chain.json disagree — needs a human
systemctl show racks-keeper -p ExecMainStatus --value | grep -qx 2 && \
  alert "exited with code 2: chain out of sync — DO NOT restart blindly, reconcile chain.json first"

# 3. the warnings the bot itself emits, since nobody reads journald
journalctl -u racks-keeper --since "-10min" --no-pager 2>/dev/null \
  | grep -E "ALERT:|WARNING:" | tail -5 | while read -r line; do alert "$line"; done

# 4. is it actually working? remaining() must fall by 3 per day (one reveal per 8h epoch)
if [ -n "${SEED:-}" ] && [ -n "${RPC:-}" ] && command -v cast >/dev/null; then
  REM=$(cast call "$SEED" "remaining()(uint256)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
  PREV_FILE=/tmp/racks-keeper-remaining
  if [ -n "$REM" ] && [ -f "$PREV_FILE" ]; then
    PREV=$(cat "$PREV_FILE"); AGE=$(( $(date +%s) - $(stat -c %Y "$PREV_FILE") ))
    # more than nine hours without a single reveal means an epoch was missed
    [ "$AGE" -gt 32400 ] && [ "$REM" = "$PREV" ] && \
      alert "remaining() has not moved in $((AGE/3600))h — reveals are not landing"
  fi
  [ -n "$REM" ] && echo "$REM" > "$PREV_FILE"
fi
