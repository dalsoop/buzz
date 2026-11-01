#!/usr/bin/env bash
# Weekly Buzz KO update, run on pop-os by the systemd user timer
# buzz-ko-auto-update.timer:
#
#   merge upstream/main into korean → catalog, type, test and untranslated-copy
#   checks → push → test build on m5m1 → install on every Buzz KO device.
#
# Nothing is pushed, built or installed when a step fails; the failure goes to
# the Buzz 사람-필요 channel (key buzz-ko/auto-update) and the merge is undone.
# A later successful run resolves that notice.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="$HOME/.local/state/buzz-ko"
mkdir -p "$LOG_DIR"
NOTICE_KEY="buzz-ko/auto-update"
INSTALL_DEVICES=(m5m1 m1m1 m1m2)

push_git() { git -c credential.helper= -c credential.helper='!gh auth git-credential' push -q "$@"; }

notify() { # notify <post|resolve> [title] [body]
  local action="$1" title="${2:-}" body="${3:-}"
  if [[ "$action" == resolve ]]; then
    ko/fleet.sh run m5m1 "export PATH=/opt/homebrew/bin:\$HOME/.local/bin:\$PATH; agent-ops-monitor notify resolve --key $NOTICE_KEY --json >/dev/null" || true
  else
    ko/fleet.sh run m5m1 "export PATH=/opt/homebrew/bin:\$HOME/.local/bin:\$PATH; agent-ops-monitor notify post --key $NOTICE_KEY --channel human-needed --title $(printf %q "$title") --body $(printf %q "$body") --link 'ssh jeonghan@pop-os journalctl --user -u buzz-ko-auto-update' --json >/dev/null" || true
  fi
}

fail() {
  echo "FAILED: $1" >&2
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then git merge --abort; fi
  git reset -q --hard "$START"
  notify post "Buzz KO 자동 업데이트 실패: $1" "$2"
  exit 1
}

[[ "$(git rev-parse --abbrev-ref HEAD)" == korean ]] || { echo "not on korean" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "working tree not clean" >&2; exit 1; }
git fetch -q upstream
git fetch -q origin
git merge -q --ff-only origin/korean
START="$(git rev-parse HEAD)"

behind="$(git rev-list --count HEAD..upstream/main)"
if [[ "$behind" -eq 0 ]]; then
  echo "korean is up to date with upstream"
  exit 0
fi
echo "merging $behind upstream commits"

if ! git merge -q --no-edit upstream/main; then
  conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  fail "병합 충돌" "upstream $behind 커밋 병합 중 충돌: $conflicts. 사람이 직접 풀어야 합니다(~/buzz, korean 브랜치)."
fi

(
  cd desktop
  pnpm install --frozen-lockfile >/dev/null
  pnpm -s i18n:check >/dev/null
  pnpm -s typecheck
  pnpm test >"$LOG_DIR/desktop-test.log" 2>&1
) || fail "검사 실패" "upstream $behind 커밋 병합 뒤 desktop 검사(카탈로그·타입·테스트)가 실패했습니다. 병합은 되돌렸습니다."

new_copy="$(cd desktop/src && python3 ../../ko/i18n-audit.py --baseline ../../ko/i18n-audit-baseline.txt . features shared app)" \
  || fail "번역 누락" "upstream 이 번역 없이 화면 문구를 더했습니다: $(echo "$new_copy" | head -5 | tr '\n' ';'). ko.additional.json 에 번역을 넣거나 기준선에 더하세요. 병합은 되돌렸습니다."

git commit -q --amend -s --no-edit
push_git origin korean || fail "push 실패" "korean 브랜치를 포크에 올리지 못했습니다."

ko/fleet.sh job m5m1 ko-auto "cd /Volumes/Build/m5m1/buzz-ko && git fetch -q origin && git checkout -q korean && git reset -q --hard origin/korean && ko/build-mac.sh test-build" \
  || fail "빌드 시작 실패" "m5m1 에서 빌드를 시작하지 못했습니다(내장 디스크 여유 부족일 수 있습니다)."
ko/fleet.sh wait m5m1 ko-auto || fail "빌드 실패" "m5m1 테스트 빌드가 실패했거나 멈췄습니다. 로그: m5m1:/tmp/fleet-ko-auto.log"

zip="$LOG_DIR/Buzz_KO_test.zip"
ko/fleet.sh fetch m5m1 /Volumes/Build/m5m1/buzz-ko/ko/dist-test/Buzz_KO_test.zip "$zip"
ko/fleet.sh install "$zip" "${INSTALL_DEVICES[@]}"

notify resolve
echo "updated to $(git rev-parse --short HEAD) and installed on ${INSTALL_DEVICES[*]}"
