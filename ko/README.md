# Buzz KO (한국어판) macOS 빌드

`korean` 브랜치의 한국어 Buzz를 **Buzz KO**라는 별도 앱으로 빌드·서명·공증·배포한다.
공식 Buzz와 번들 ID, 키체인 항목, 데이터 폴더, 딥링크, CLI 이름이 모두 달라서 나란히 설치된다.
설치된 앱은 이 포크의 Releases(`buzz-ko-latest`)에서 자동 업데이트를 받는다.

## 처음 한 번 (빌드용 Mac)

평소 Mac 앱 릴리스와 같은 서명 체계를 쓴다.

| 항목 | 출처 |
|---|---|
| 코드 서명 | 로그인 키체인의 `Developer ID Application` 인증서 |
| 공증 | 기존 notarytool 키체인 프로필 `swift-app-mono` (`BUZZ_KO_NOTARY_PROFILE`로 바꿀 수 있음) |
| 업데이트 서명 키 | Bitwarden 원본 → `principal-secrets-mono`의 `secrets/macbook-tools/buzz-ko-tauri-updater-key.enc.yaml` (필드 `value`, `password`) |
| 업데이트 공개키 | 이 저장소의 `ko/updater.pub` |

`principal-secrets-mono` 경로가 기본값(`~/Documents/workspace/gitlab-saas/gujoai/infra/principal-secrets-mono`)과 다르면 `BUZZ_KO_SECRETS_REPO`로 지정한다.
`sops`, `age-plugin-se`, `gh auth login`이 준비돼 있어야 한다.

```bash
git clone https://github.com/dalsoop/buzz.git && cd buzz
git checkout korean
ko/build-mac.sh setup
```

`setup`은 서명 인증서와 공증 프로필을 확인한다. 업데이트 키가 아직 없으면 한 번 만들고,
공개키를 `ko/updater.pub`에 쓴 뒤 개인키를 Bitwarden에 넣고 `environment-secret-broker sync`로
암호문을 만들 때까지 기다린다. 임시 개인키 파일은 끝나면 지운다. `ko/updater.pub`은 커밋한다.
**이 개인키를 잃으면 이미 설치된 앱이 업데이트를 못 받는다.**

## 릴리스할 때마다

```bash
git pull
ko/build-mac.sh build 0.5.28     # ko/dist/에 서명·공증된 dmg와 업데이트 파일 생성
ko/build-mac.sh publish 0.5.28   # GitHub Releases(ko-v0.5.28)에 올리고 업데이트 피드 갱신
```

- 버전을 생략하면 `desktop/package.json` 버전을 쓴다.
- 자동 업데이트는 **더 높은 버전**만 설치한다. 같은 upstream 버전을 다시 내려면 버전을 올려서(예: 0.5.29) 빌드한다.
- 빌드한 Mac의 아키텍처용 dmg만 나온다. Apple Silicon Mac에서 빌드하면 Apple Silicon용이다.

## 설치하는 쪽 (각 Mac)

1. https://github.com/dalsoop/buzz/releases 에서 `Buzz_KO_<버전>_aarch64.dmg`를 받는다.
2. 열어서 **Buzz KO**를 응용 프로그램 폴더로 끈다.
3. 이후 업데이트는 앱이 알아서 받는다.

## 알아둘 점

- 웹 페이지의 "Buzz에서 열기"·초대 링크(`buzz://`)는 공식 Buzz를 연다. Buzz KO에서는 초대 링크를 복사해 앱의 "초대 링크 또는 코드" 칸에 붙여 넣는다.
- `BUILD_ID`(build-mac.sh)는 절대 바꾸지 않는다. 바꾸면 macOS가 다른 앱으로 인식해 데이터와 업데이트가 끊긴다.

## 원격 빌드 주의 (m5m1)

- m5m1의 tmux 서버는 GUI 쪽 프로세스라 외장 볼륨(`/Volumes/Build`)을 읽을 때 macOS 권한 창을 띄우고 **조용히 멈춘다** (로그 0바이트). SSH로 원격 실행할 때는 tmux 말고 `ssh m5m1 'cd … && nohup ko/build-mac.sh … > log 2>&1 &'`를 쓴다.
- 영구 해결: m5m1에서 시스템 설정 → 개인정보 보호 및 보안 → 파일 및 폴더(또는 전체 디스크 접근)에서 `/opt/homebrew/bin/tmux`에 **이동식 볼륨** 접근을 허용한다.
- 진행 확인은 로그 크기로 한다. 로그가 10분 넘게 그대로면 멈춘 것으로 본다.

## 장비 프로필 (`ko/devices.json`, `ko/fleet.sh`)

장비별 SSH 계정·경유 경로·작업 폴더·sops 키·역할은 `ko/devices.json` 한 곳에만 둔다. 스크립트는 장비 이름만 받는다.

```bash
ko/fleet.sh check                         # 장비별 접속·여유 공간·설치 버전
ko/fleet.sh job m5m1 build "cd /Volumes/Build/m5m1/buzz-ko && ko/build-mac.sh test-build"
ko/fleet.sh wait m5m1 build               # 로그가 10분 멈추면 실패로 끝남
ko/fleet.sh install Buzz_KO.zip           # roles에 install이 있는 모든 장비
```

`via`가 있는 장비(예: m1m2)는 그 장비를 거쳐 접속하므로 이 머신의 키를 등록할 필요가 없다.

## 승인 요청

소유자 승인이 필요한 MR(예: principal-secrets-mono 의 `delivery.yaml`)은 m5m1 에서 Buzz `사람-필요` 채널로 링크와 함께 알린다
(`agent-ops-monitor notify post --channel human-needed …`). 머지되면 같은 key 로 resolve 한다.
