#!/bin/bash
# Builds a copy of Wherever Host to give to someone else: dist/WhereverHost-<version>.zip holding the
# app and the manual. It carries no relay, password, Mac ID or other settings of this Mac;
# the other Mac makes its own, and reaches it from outside with Tailscale or its own relay.
set -euo pipefail
cd "$(dirname "$0")"

env -u RELAY_URL ./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/WhereverHost.app/Contents/Info.plist)"
NAME="WhereverHost-$VERSION"
DIST="../dist"
mkdir -p "$DIST"
rm -rf "${DIST:?}/$NAME" "$DIST/$NAME.zip"
mkdir "$DIST/$NAME"
ditto build/WhereverHost.app "$DIST/$NAME/WhereverHost.app"
[ -f ../docs/manual.html ] && cp ../docs/manual.html "$DIST/$NAME/사용 설명서.html"
cp ../THIRD_PARTY_NOTICES.md "$DIST/$NAME/"

# The relay, for the other person to deploy on their own Cloudflare account (never this one's):
# setup-relay.command does it and fills the viewer from their installed app (assets: ./web).
RELAY="$DIST/$NAME/중개 서버 만들기"
mkdir "$RELAY"
cp -R ../relay/src ../relay/package.json ../relay/package-lock.json ../relay/set-turn-secrets.sh "$RELAY/"
sed 's#"directory": "../host/Resources/web"#"directory": "./web"#' ../relay/wrangler.jsonc > "$RELAY/wrangler.jsonc"
grep -q '"./web"' "$RELAY/wrangler.jsonc"
cp ../relay/setup-relay.command "$RELAY/중개 서버 만들기.command"
chmod +x "$RELAY/중개 서버 만들기.command" "$RELAY/set-turn-secrets.sh"
ditto -c -k --norsrc --noextattr --keepParent "$DIST/$NAME" "$DIST/$NAME.zip"
rm -rf "${DIST:?}/$NAME"
echo "Packaged $DIST/$NAME.zip ($(du -h "$DIST/$NAME.zip" | cut -f1))"
