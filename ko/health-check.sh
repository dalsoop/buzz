#!/usr/bin/env bash
# Buzz KO health check, run on pop-os every 2 hours by the systemd user timer
# buzz-ko-health.timer.
#
# For every device with a buzz_ko_account in ko/devices.json:
#   - reachable but Buzz KO not running  → Buzz 서버-알림 notice
#     (key buzz-ko/down/<device>), resolved once it runs again;
#   - unreachable → only devices marked always_on alert; Macs that are off or
#     asleep are not an incident.
# Also keeps each LaunchAgent's stderr log under 5 MB (one rotated copy).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
notify() { # notify <post|resolve> <key> [title] [body]
  if [[ "$1" == resolve ]]; then
    ko/fleet.sh notify resolve "$2" || true
  else
    ko/fleet.sh notify post "$2" server-alerts "$3" "$4" || true
  fi
}

field() { python3 -c 'import json,sys; print(json.load(open("ko/devices.json"))["devices"][sys.argv[1]].get(sys.argv[2], ""))' "$1" "$2"; }

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
    stopped) notify post "$key" "Buzz KO 꺼짐: $dev" "$dev 에서 Buzz KO 가 실행 중이 아닙니다. 다시 켜기: 앱을 직접 실행하거나, LaunchAgent 가 있는 장비는 ko/fleet.sh install-agent $dev." ;;
    unreachable)
      if [[ "$(field "$dev" always_on)" == True ]]; then
        notify post "$key" "Buzz KO 장비 연결 안 됨: $dev" "$(hostname -s) 에서 $dev 로 SSH 가 되지 않습니다. 장비 전원·네트워크를 확인하세요."
      fi ;;
  esac
done

for dev in $devices; do
  [[ -n "$(field "$dev" launch_agent)" ]] || continue
  ko/fleet.sh run "$dev" '
    for f in "$HOME"/Library/Logs/buzz-ko/*.err.log; do
      [ -f "$f" ] && [ "$(stat -f %z "$f")" -gt 5242880 ] && cp "$f" "$f.1" && : > "$f" && echo "rotated $f"
    done
  ' 2>/dev/null || true
done
