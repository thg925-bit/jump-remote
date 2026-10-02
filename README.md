# Jump — 개인용 Mac 원격 데스크톱

집에 있는 Mac을 밖에서 MacBook·PC(브라우저), 아이폰·아이패드, 안드로이드로 조작하는 개인 프로젝트.
Jump Desktop과는 관계없는 별개의 프로그램입니다.

## 그냥 쓰려면 (빌드 없이)

[Releases](../../releases/latest)에서 받습니다.

- **`JumpHost-<버전>.zip`** — Mac 앱, 사용 설명서(`사용 설명서.html`), 밖에서 접속할 때 필요한 `중개 서버 만들기` 스크립트.
  설명서 순서대로 설치하면 됩니다. 중개 서버는 각자 자기 Cloudflare 무료 계정에 만들어지고, 그 Mac만 쓸 수 있게 잠깁니다.
- **`jump-android-<버전>.apk`** — 안드로이드 앱(arm64). 아이폰·아이패드·PC는 앱 없이 브라우저로 접속합니다.

필요한 것: Apple 칩 Mac, macOS 14 이상. App Store 앱이 아니라서 처음 열 때 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**가 필요합니다.

화면·소리·입력은 기기와 Mac이 직접(WebRTC, 암호화) 주고받고, 비밀번호는 네트워크로 보내지 않습니다(확인 값만). 자세한 내용은 아래 **보안**과 `PROTOCOL.md`.

## 개발

| 폴더 | 내용 |
|---|---|
| `host/` | Mac 메뉴바 앱 (Swift). 화면 캡처 → H.264 하드웨어 인코딩 → WebRTC, 입력 주입 |
| `client/` | iPad·안드로이드 앱 (Flutter) |
| `host/Resources/web/` | 브라우저 뷰어 (앱 설치 없이 Safari/Chrome에서 사용) |
| `PROTOCOL.md` | 호스트 ↔ 클라이언트 메시지 규격 |

## Mac 호스트

```bash
cd host && ./build.sh install
```

`~/Applications/JumpHost.app`에 설치하고 실행한다. 메뉴바 모니터 아이콘에서 접속 주소·비밀번호(⌥ 누르면 보임)·화질을 본다.
처음 실행하면 앱 안의 LaunchAgent(`Contents/Library/LaunchAgents`, `SMAppService.agent`)를 등록해
로그인 시 자동 실행되고, 오류로 죽으면 launchd가 다시 띄운다(메뉴에서 종료한 것은 그대로 둔다). 메뉴 **로그인 시 자동 실행 · 멈추면 다시 켜기**로 끈다.
아이콘이 노치 뒤에 숨으면 JumpHost를 다시 열면(Spotlight 등) 같은 메뉴가 마우스 위치에 뜬다.
연결 기록: `~/Library/Logs/JumpHost/host.log` (메뉴 **연결 기록 보기**) — 세션 시작/종료 이유, 재연결 이유, 5초마다 경로·화질.
다른 사람에게 줄 때는 `host/package.sh` → `dist/JumpHost-<버전>.zip` (앱 + `docs/manual.html`).
이 zip에는 중개 서버 주소·비밀번호·Mac ID가 들어가지 않는다. 받은 쪽은 zip 안의 `중개 서버 만들기.command`
(= `relay/setup-relay.command`)로 자기 Cloudflare 계정에 중개 서버를 만든다: Node.js 확인 → wrangler 로그인 →
배포 → `HOST_IDS`를 그 Mac ID로 → 호스트에 주소 설정 후 재시작. 다시 실행해도 된다(업데이트 후 뷰어 갱신).
비밀번호는 접속한 기기에서도 바꿀 수 있다: 툴바 ⚙ 설정 → Mac 비밀번호 변경 (현재 비밀번호 필요).

첫 실행 시 시스템 설정 → 개인정보 보호 및 보안에서 두 권한을 켠다.
- **화면 및 시스템 오디오 녹음** — 화면 전송
- **손쉬운 사용** — 마우스·키보드 입력

서명이 ad-hoc이면 재빌드할 때마다 권한을 다시 켜야 한다. Xcode에 Apple ID로 로그인하면 `Apple Development` 인증서가 생기고, `build.sh`가 자동으로 그걸로 서명해 권한이 유지된다.

포트: 47865 (WebSocket 신호), 47866 (브라우저 뷰어).

소리: 맥 시스템 소리를 웹 뷰어와 안드로이드 앱으로 보낸다. 소리는 한 곳에서만 난다 — 뷰어의
`🔊 아이패드 재생` ↔ `💻 맥북에어 재생` 토글을 따라 맥 스피커를 음소거/복구하고, 끊기면 되돌린다
(메뉴 "소리 전송", "연결 중 Mac 소리 끄기").

## 클라이언트

**브라우저**: iPad Safari / 안드로이드 Chrome에서 `http://<Mac 주소>:47866` 열기.

**안드로이드 앱**:
```bash
cd client && flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk 를 폰에 설치
```

**iPad 앱** (Xcode 필요): iPad를 USB로 연결하고
```bash
cd client && flutter run --release
```
무료 Apple ID로 서명하면 7일마다 다시 설치해야 한다.

## 조작

**웹 뷰어 트랙패드 스틱** — 화면 구석의 투명한 원 + 하얀 콩, 툴바 🖱 로 오른쪽 → 왼쪽 → 숨김

맥북 트랙패드처럼 손가락이 움직인 만큼 커서가 움직이고, macOS와 같은 포인터 가속을 쓴다
(이 맥의 `HIDAccelCurves`를 그대로 사용 — 천천히는 정밀, 빠르게 휙은 멀리). 원 안에서 시작하면
손가락이 원 밖으로 나가도 계속 추적한다. 툴바 "속도" = macOS 이동 속도 단계 0.6875 / 1.0 / 1.5.

| 조작 | 결과 |
|---|---|
| 콩 끌기 | 커서 이동 |
| 탭 / 두 번 탭 | 클릭 / 더블클릭 |
| 길게 누르기 (파란 테두리) | 우클릭 |
| 길게 누른 뒤 끌기 (파란 콩) | 드래그 |
| 화면 두 손가락 끌기 | 스크롤 |

화면 직접 터치(아래 "터치 모드")도 그대로 된다. 앱은 모드 버튼으로 터치/트랙패드를 바꾼다.

| 동작 | 터치 모드 | 트랙패드 모드 |
|---|---|---|
| 클릭 | 누른 곳 탭 | 탭 (커서 위치) |
| 드래그 | 누르고 끌기 | 탭 후 바로 누르고 끌기 |
| 우클릭 | 길게 누르기 / 두 손가락 탭 | 두 손가락 탭 |
| 스크롤 | 두 손가락 끌기 | 두 손가락 끌기 |
| 확대 (앱만) | 두 손가락 벌리기 | 두 손가락 벌리기 |

- 하드웨어 키보드: 키 코드 그대로 전달, 한글 조합은 Mac 입력기가 처리 (Mac에서 한/영 전환).
- 소프트 키보드: 조합이 끝난 글자를 전송. 보조키 바의 ⌘⌃⌥⇧는 한 번 누르면 다음 키에 적용 (⌘ → c = 복사).

## 외부 접속

**중개 서버 (추천, VPN 불필요)** — `relay/`의 Cloudflare Worker (무료 플랜). 맥이 먼저 접속해 대기하고,
뷰어는 맥 메뉴의 **"어디서나 접속"** 링크(`https://jump-relay.<내 workers.dev 이름>.workers.dev/#id=<Mac ID>`)를 열어
비밀번호로 접속한다. 영상은 기기끼리 직접(WebRTC) 가고, 중개 서버는 연결만 소개한다.
```bash
cd relay && npm install && npx wrangler login && npx wrangler deploy
```
그다음 맥 메뉴 **중개 서버 주소 설정…**에 worker 주소를 넣는다. 중개 서버는 각자 자기 Cloudflare 계정에 배포한다.
자기 맥만 쓰게 잠그려면 메뉴 링크의 `#id=` 값을 `HOST_IDS` 비밀값으로 넣는다(쉼표로 여러 대):
```bash
npx wrangler secret put HOST_IDS
```
Mac ID는 처음 접속한 Mac의 토큰이 차지한다. 맥 설정을 지워 토큰이 바뀌면 중개 서버가 409로 거부하고 메뉴에 이유가 뜬다.
`HOST_RESET`을 `<Mac ID>:<새 값>`으로 넣으면 다음에 접속하는 Mac이 그 ID를 한 번 다시 차지한다(`setup-relay.command`가 매번 넣는다).
직접 연결이 막히는 망(회사망 등 UDP 차단)을 위한 TURN — Cloudflare Realtime, 월 1,000GB 무료.
대시보드 Realtime → TURN Server에서 키를 만든 뒤 `relay/set-turn-secrets.sh`를 실행하면 값을 검증하고 저장한다.
직접 연결이 되면 TURN은 쓰이지 않는다 (호스트 로그 `path srflx->srflx` = 직접, `relay` = 중계).

**Tailscale**

Mac·iPad·폰에 Tailscale을 설치하고 같은 계정으로 로그인한 뒤, 메뉴에 `(Tailscale)`로 표시되는 100.x 주소로 접속한다.
공용 와이파이에서는 LAN 주소 대신 Tailscale 주소만 쓸 것.

## 보안

- 비밀번호는 로그인 때 전송되지 않고 매 접속마다 새 nonce의 HMAC-SHA256만 오간다. 1분에 5회 실패하면 그 출처(IP, 중개 서버 경유는 중개 서버가 본 IP)만 1분 잠기고, 반복되면 최대 1시간까지 두 배씩 늘어난다.
- 브라우저는 이 Mac이 제공하는 뷰어 페이지(Origin이 웹 포트)에서만 신호 소켓을 열 수 있다. 같은 LAN의 다른 웹페이지가 비밀번호를 맞혀 보는 것을 막는다.
- 웹 뷰어는 개인 기기(아이폰·아이패드·Mac·안드로이드, 홈 화면 앱)에서만 기본으로 비밀번호를 기억한다. 다른 PC에서는 탭을 닫으면 잊는다.
- 호스트는 비밀번호를 UserDefaults에 둔다. Keychain은 자체 서명 앱이 업데이트될 때마다 Mac 화면에 허용 창을 띄워, 원격 접속이 그 창에 막힐 수 있어서 쓰지 않는다.
- 원격 비밀번호 변경은 로그인된 세션의 input 데이터 채널(DTLS, 기기↔Mac 종단 간)로만 가며 현재 비밀번호를 다시 요구한다. 틀린 시도도 잠금 횟수에 들어간다.
- 화면·입력 데이터는 WebRTC(DTLS-SRTP)로 암호화된다. 신호 채널(ws://)은 평문이라 LAN에서는 SDP 변조가 이론상 가능하다 → 외부에서는 Tailscale로 감쌀 것.
- 클라이언트 앱은 비밀번호를 기기에 평문(SharedPreferences)으로 저장한다.
