#!/usr/bin/env bash
# Run Buzz KO work across the Macs described in ko/devices.json.
#
#   ko/fleet.sh check                      reachability + facts per device
#   ko/fleet.sh list [role]                device names (optionally by role)
#   ko/fleet.sh run <device> <command>     run a shell command on a device
#   ko/fleet.sh job <device> <name> <cmd>  start a detached job (ssh + nohup)
#   ko/fleet.sh wait <device> <name>       wait for a job; fails if its log
#                                          stops growing for 10 minutes
#   ko/fleet.sh fetch <device> <remote> <local>
#   ko/fleet.sh install <Buzz_KO.zip> [device…]
#                                          install on every "install" device
#
# Devices with "via" are reached through that device (nested ssh), so this
# host never needs its key authorized there.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICES="$ROOT/ko/devices.json"
APP_NAME="Buzz KO"
STALL_SECS=600

die() { echo "error: $*" >&2; exit 1; }

field() { # field <device> <key> -> value or empty
  python3 - "$DEVICES" "$1" "$2" <<'EOF'
import json, sys
path, name, key = sys.argv[1:]
d = json.load(open(path))["devices"].get(name)
if d is None:
    sys.exit(f"unknown device: {name}")
v = d.get(key, "")
print(" ".join(v) if isinstance(v, list) else v)
EOF
}

names() { # names [role]
  python3 - "$DEVICES" "${1:-}" <<'EOF'
import json, sys
path, role = sys.argv[1:]
for n, d in json.load(open(path))["devices"].items():
    if not role or role in d.get("roles", []):
        print(n)
EOF
}

# Run a bash script (stdin) on a device, hopping through "via" when set.
remote() {
  local dev="$1" target via
  target="$(field "$dev" ssh)"
  via="$(field "$dev" via)"
  if [[ -n "$via" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$(field "$via" ssh)" \
      "ssh -o BatchMode=yes -o ConnectTimeout=10 $target bash -s"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" bash -s
  fi
}

# Stream a local file to a path on a device.
push() {
  local dev="$1" src="$2" dst="$3"
  local target via
  target="$(field "$dev" ssh)"
  via="$(field "$dev" via)"
  if [[ -n "$via" ]]; then
    ssh -o BatchMode=yes "$(field "$via" ssh)" \
      "ssh -o BatchMode=yes $target $(printf '%q' "cat > $(printf '%q' "$dst")")" <"$src"
  else
    ssh -o BatchMode=yes "$target" "cat > $(printf '%q' "$dst")" <"$src"
  fi
}

cmd_check() {
  local dev
  for dev in $(names); do
    printf '%-6s ' "$dev"
    remote "$dev" <<'EOF' 2>/dev/null || echo "unreachable"
printf 'ok user=%s os=%s free=%s' "$(whoami)" "$(sw_vers -productVersion)" \
  "$(df -h / | awk 'NR==2{print $4}')"
app="/Applications/Buzz KO.app"
[ -d "$app" ] && printf ' buzz-ko=%s' \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
pgrep -qf "Buzz KO.app/Contents/MacOS/" && printf ' buzz-ko-running'
echo
EOF
  done
}

cmd_job() {
  local dev="$1" name="$2"; shift 2
  local cmd="$*" root min
  root="$(field "$dev" work_root)"
  min="$(field "$dev" internal_min_free_gb)"
  # Keep temp files and download caches off the internal disk.
  if [[ -n "$root" ]]; then
    cmd="export TMPDIR=$root/cache/tmp CARGO_HOME=$root/cache/cargo npm_config_store_dir=$root/cache/pnpm-store npm_config_cache=$root/cache/npm HERMIT_STATE_DIR=$root/cache/hermit; mkdir -p \$TMPDIR; $cmd"
  fi
  remote "$dev" <<EOF
free_gb=\$(df -g / | awk 'NR==2{print \$4}')
if [ -n "$min" ] && [ "\$free_gb" -lt "$min" ]; then
  echo "refused: internal disk has \${free_gb}GB free, below ${min}GB" >&2
  exit 3
fi
log=/tmp/fleet-$name.log
: > "\$log"
nohup bash -lc $(printf '%q' "export PATH=/opt/homebrew/bin:\$HOME/.cargo/bin:\$PATH; $cmd; echo EXIT=\$?") >> "\$log" 2>&1 < /dev/null &
echo "started $name on \$(hostname -s), log \$log"
EOF
}

cmd_wait() {
  local dev="$1" name="$2" last=-1 still=0 size out
  while :; do
    out="$(remote "$dev" <<<"stat -f %z /tmp/fleet-$name.log; grep -m1 '^EXIT=' /tmp/fleet-$name.log || true")"
    size="$(head -1 <<<"$out")"
    if grep -q '^EXIT=' <<<"$out"; then
      grep '^EXIT=' <<<"$out"
      [[ "$(grep '^EXIT=' <<<"$out")" == "EXIT=0" ]]
      return
    fi
    if [[ "$size" == "$last" ]]; then still=$((still + 30)); else still=0; last="$size"; fi
    (( still < STALL_SECS )) || die "$name on $dev stalled: log unchanged for $STALL_SECS s at $size bytes"
    sleep 30
  done
}

cmd_install() {
  local zip="$1"; shift
  [[ -f "$zip" ]] || die "zip not found: $zip"
  local devs=("$@") dev
  ((${#devs[@]})) || mapfile -t devs < <(names install)
  for dev in "${devs[@]}"; do
    printf '%-6s ' "$dev"
    if ! remote "$dev" <<<"true" 2>/dev/null; then echo "skipped (unreachable)"; continue; fi
    push "$dev" "$zip" "/tmp/Buzz_KO.zip"
    remote "$dev" <<EOF || echo "FAILED"
set -e
app="/Applications/$APP_NAME.app"
osascript -e 'quit app "$APP_NAME"' >/dev/null 2>&1 || true
sleep 1
rm -rf /tmp/buzz-ko-unzip && mkdir /tmp/buzz-ko-unzip
ditto -x -k /tmp/Buzz_KO.zip /tmp/buzz-ko-unzip
rm -rf "\$app"
mv "/tmp/buzz-ko-unzip/$APP_NAME.app" "\$app"
xattr -dr com.apple.quarantine "\$app" 2>/dev/null || true
rm -rf /tmp/buzz-ko-unzip /tmp/Buzz_KO.zip
codesign --verify --deep --strict "\$app"
open "\$app"
for i in \$(seq 1 20); do pgrep -f "\$app/Contents/MacOS/" >/dev/null && break; sleep 1; done
pgrep -f "\$app/Contents/MacOS/" >/dev/null && echo "installed, running" || echo "installed, NOT running"
EOF
  done
}

case "${1:-}" in
  check) cmd_check ;;
  list) names "${2:-}" ;;
  run) dev="$2"; shift 2; remote "$dev" <<<"$*" ;;
  job) shift; cmd_job "$@" ;;
  wait) cmd_wait "$2" "$3" ;;
  fetch) dev="$2"; remote "$dev" <<<"cat $(printf '%q' "$3")" > "$4" ;;
  install) shift; cmd_install "$@" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
