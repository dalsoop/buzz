# Buzz KO (한국어판) macOS 빌드

`korean` 브랜치의 한국어 Buzz를 **Buzz KO**라는 별도 앱으로 빌드·서명·공증·배포한다.
공식 Buzz와 번들 ID, 키체인 항목, 데이터 폴더, 딥링크, CLI 이름이 모두 달라서 나란히 설치된다.
설치된 앱은 이 포크의 Releases(`buzz-ko-latest`)에서 자동 업데이트를 받는다.

## 처음 한 번 (빌드용 Mac)

준비물: Xcode Command Line Tools, 키체인에 **Developer ID Application** 인증서,
App Store Connect API 키(.p8) 또는 Apple ID 앱 암호, `gh auth login` 완료.

```bash
git clone https://github.com/dalsoop/buzz.git && cd buzz
git checkout korean
ko/build-mac.sh setup
```

`setup`이 하는 일:

- `~/.buzz-ko/updater.key`에 자동 업데이트 서명 키를 만든다. **이 키를 잃으면 이미 설치된 앱이 업데이트를 못 받는다.** 따로 백업할 것.
- 공증 자격 증명을 키체인 프로필 `buzz-ko`에 저장한다.

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
