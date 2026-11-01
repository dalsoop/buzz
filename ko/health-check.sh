#!/usr/bin/env bash
# Buzz KO health check, run on pop-os every 2 hours by the systemd user timer
# buzz-ko-health.timer.
#
# For every device with a buzz_ko_account in ko/devices.json:
#   - reachable but Buzz KO not running  → Buzz 서버-알림 notice
#     (key buzz-ko/down/<device>), resolved once it runs again;
#   - unreachable → only m5m1 alerts (it is always on); Mac laptops/minis that
#     are off or asleep are not an incident.
# Also keeps the m5m1 bot's stderr log under 5 MB (one rotated copy).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ALWAYS_ON=(m5m1)

notify() { # notify <post|resolve> <key> [title] [body]
  local action="$1" key="$2" title="${3:-}" body="${4:-}" cmd
  if [[ "$action" == resolve ]]; then
    cmd="agent-ops-monitor notify resolve --key $key --json"
  else
    cmd="agent-ops-monitor notify post --key $key --channel server-alerts --title $(printf %q "$title") --body $(printf %q "$body") --json"
  fi
  ko/fleet.sh run m5m1 "export PATH=/opt/homebrew/bin:\$HOME/.local/bin:\$PATH; $cmd >/dev/null" || true
}

devices="$(python3 -c '
import json
for n, d in json.load(open("ko/devices.json"))["devices"].items():
    if d.get("buzz_ko_account"): print(n)')"

for dev in $devices; do
  key="buzz-ko/down/$dev"
  state="$(ko/fleet.sh run "$dev" '
    pgrep -qf "^/Applications/Buzz KO.app/Contents/MacOS/buzz-desktop" && echo running || echo stopped
  ' 2>/dev/null)" || state=unreachable
  echo "$dev: $state"
  case "$state" in
    running) notify resolve "$key" ;;
    stopped) notify post "$key" "Buzz KO 꺼짐: $dev" "$dev 에서 Buzz KO 가 실행 중이 아닙니다. 다시 켜기: ko/fleet.sh install 또는 앱 실행(m5m1 은 launchctl kickstart gui/\$(id -u)/net.ranode.buzz-ko.m5m1-ops)." ;;
    unreachable)
      if [[ " ${ALWAYS_ON[*]} " == *" $dev "* ]]; then
        notify post "$key" "Buzz KO 장비 연결 안 됨: $dev" "pop-os 에서 $dev 로 SSH 가 되지 않습니다. 장비 전원·네트워크를 확인하세요."
      fi ;;
  esac
done

ko/fleet.sh run m5m1 '
  f="$HOME/Library/Logs/buzz-ko/m5m1-ops.err.log"
  if [ -f "$f" ] && [ "$(stat -f %z "$f")" -gt 5242880 ]; then
    cp "$f" "$f.1" && : > "$f" && echo "rotated m5m1 bot log"
  fi
' || true
