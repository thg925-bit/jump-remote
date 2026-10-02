#!/bin/bash
# Jump 중개 서버 만들기: deploys this relay to your own Cloudflare account (free plan), keeps it
# to this Mac only, and points this Mac's Jump Host at it. Double-click in Finder, or run it in
# Terminal. Safe to run again (after updating Jump, for example): it just deploys again.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() {
  printf '\n\033[31m✗ %s\033[0m\n\n' "$*"
  read -r -p "Enter를 누르면 닫힙니다" _ || true
  exit 1
}

say "Jump 중개 서버 만들기"

# Node.js runs Cloudflare's deploy tool (wrangler).
if ! command -v npx >/dev/null 2>&1; then
  open "https://nodejs.org/ko/download"
  fail "Node.js가 필요합니다. 방금 열린 페이지에서 macOS 설치 프로그램(.pkg, LTS)을 받아 설치한 뒤 이 파일을 다시 실행하세요."
fi
node_major=$(node -p 'process.versions.node.split(".")[0]')
if [ "$node_major" -lt 22 ]; then
  open "https://nodejs.org/ko/download"
  fail "Node.js $node_major 버전은 오래됐습니다. 방금 열린 페이지에서 최신 LTS를 설치한 뒤 다시 실행하세요."
fi

# Jump Host creates this Mac's ID on its first launch.
mac_id=$(defaults read com.jihun.jumphost macID 2>/dev/null || true)
[ -n "$mac_id" ] || fail "Jump Host를 먼저 한 번 실행하세요. 메뉴바에 아이콘이 생기면 됩니다."

# In a shared copy the viewer page comes from the installed app, so the relay serves the same
# version as the Mac. (In the source tree wrangler.jsonc points at host/Resources/web instead.)
if grep -q '"./web"' wrangler.jsonc; then
  rm -rf web
  for app in "/Applications/JumpHost.app" "$HOME/Applications/JumpHost.app"; do
    if [ -d "$app/Contents/Resources/web" ]; then
      cp -R "$app/Contents/Resources/web" web
      break
    fi
  done
  [ -d web ] || fail "JumpHost.app을 찾지 못했습니다. 응용 프로그램 폴더에 넣은 뒤 다시 실행하세요."
fi

say "1/4 도구 준비 (처음에는 1~2분 걸립니다)"
npm install --no-audit --no-fund --loglevel=error || fail "도구를 받지 못했습니다. 인터넷 연결을 확인하세요."

say "2/4 Cloudflare 로그인"
if npx wrangler whoami 2>/dev/null | grep -q "associated with"; then
  echo "이미 로그인되어 있습니다."
else
  echo "브라우저가 열리면 Cloudflare에 로그인하고 [Allow]를 누르세요."
  echo "(Cloudflare 계정이 없으면 dash.cloudflare.com/sign-up 에서 무료로 만든 뒤 다시 실행하세요.)"
  npx wrangler login || fail "로그인하지 못했습니다. 브라우저에서 dash.cloudflare.com에 먼저 로그인한 뒤 다시 실행하세요."
fi

say "3/4 중개 서버 올리기"
echo "workers.dev 이름을 물으면 영어 소문자로 원하는 이름을 넣고 Enter를 누르세요."
log=$(mktemp)
# `script` keeps the terminal interactive (wrangler may ask questions) while recording the output.
script -q "$log" npx wrangler deploy || fail "올리지 못했습니다. 위 메시지를 확인하세요."
url=$(grep -aoE 'https://jump-relay\.[a-z0-9-]+\.workers\.dev' "$log" | head -1 || true)
rm -f "$log"
[ -n "$url" ] || fail "중개 서버 주소를 찾지 못했습니다. 위 메시지를 확인하세요."
# Only these Macs may use it. Cloudflare can't show a secret back, so the list is kept on this
# Mac too (a second Mac on the same account is added here, not lost).
ids_file="$HOME/Library/Application Support/JumpHost/relay-host-ids"
mkdir -p "$(dirname "$ids_file")"
known=$(cat "$ids_file" 2>/dev/null || true)
echo
echo "이 Cloudflare 계정의 중개 서버를 다른 Mac도 같이 쓰나요?"
echo "그렇다면 그 Mac의 ID를 넣으세요 (Jump 메뉴 링크의 #id= 뒤, 여러 대는 쉼표로). 없으면 그냥 Enter."
[ -n "$known" ] && echo "(지난번 목록: $known)"
read -r -p "다른 Mac ID: " extra || extra=""
ids=$(printf '%s,%s,%s' "$mac_id" "$known" "$extra" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '\n' | grep -E '^[a-z0-9]{8,32}$' | awk '!seen[$0]++' | paste -sd, -)
printf '%s' "$ids" | npx wrangler secret put HOST_IDS >/dev/null || fail "이 Mac을 등록하지 못했습니다."
printf '%s' "$ids" > "$ids_file"
# If this Mac's registration on the relay no longer matches (settings wiped, reinstalled), let it
# claim its ID once more; the relay uses this value up on the Mac's next connection.
printf '%s:%s' "$mac_id" "$(date +%s)" | npx wrangler secret put HOST_RESET >/dev/null || true

say "4/4 Jump Host 연결"
defaults write com.jihun.jumphost relayURL "$url"
if pgrep -x JumpHost >/dev/null; then
  killall JumpHost || true
  sleep 2
fi
open -a JumpHost 2>/dev/null || true

link="$url/#id=$mac_id"
printf '%s' "$link" | pbcopy
say "✓ 완료"
echo "이 Mac의 '어디서나 접속' 링크 (클립보드에 복사됨):"
echo
echo "    $link"
echo
echo "Jump 메뉴에서도 볼 수 있습니다. 링크와 비밀번호만 있으면 어디서든 접속됩니다."
echo
read -r -p "Enter를 누르면 닫힙니다" _ || true
