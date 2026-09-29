#!/bin/bash
# Stores Cloudflare TURN credentials as Worker secrets, after checking them against the API.
# Values come from the clipboard and are never printed.
set -euo pipefail
cd "$(dirname "$0")"

read -r -p "1) Cloudflare 대시보드에서 'Turn Token ID' 옆 복사 버튼을 누른 뒤 Enter: " _
id_raw=$(pbpaste)
# Keep just the 32-hex key ID if a label or URL came along with it.
id=$(printf '%s' "$id_raw" | grep -oE '[0-9a-fA-F]{32}' | head -1 || true)
[ -n "$id" ] || id=$(printf '%s' "$id_raw" | tr -d '[:space:]')

read -r -p "2) 'API Token' 옆 복사 버튼을 누른 뒤 Enter: " _
token=$(pbpaste | tr -d '[:space:]')
token=${token#Bearer}

echo "   Token ID ${#id}자 / API Token ${#token}자 — Cloudflare에 확인 중…"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "https://rtc.live.cloudflare.com/v1/turn/keys/${id}/credentials/generate-ice-servers" \
  -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" -d '{"ttl":60}')
if [ "$code" != "201" ] && [ "$code" != "200" ]; then
  echo "✗ Cloudflare가 이 값을 거절했습니다 (HTTP $code)."
  [ "$code" = "404" ] && echo "   Token ID가 맞지 않습니다. TURN 키 화면의 'Turn Token ID'를 복사했는지 확인하세요."
  [ "$code" = "401" ] || [ "$code" = "403" ] && echo "   API Token이 맞지 않습니다. 안 보이면 TURN 키를 새로 만드세요."
  exit 1
fi

printf '%s' "$id" | npx wrangler secret put TURN_KEY_ID >/dev/null
printf '%s' "$token" | npx wrangler secret put TURN_KEY_API_TOKEN >/dev/null
echo "✓ TURN 설정 완료 (Cloudflare 확인 통과, 비밀값 저장됨)"
