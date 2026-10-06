#!/bin/bash
# Builds build/JumpHost.app (menu bar host). `./build.sh install` also installs to ~/Applications.
# A stable signing identity lets macOS keep the Screen Recording / Accessibility grants
# across rebuilds; ad-hoc signatures change every build and lose them.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/JumpHost.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN/JumpHost" "$APP/Contents/MacOS/"
# Debug-map entries hold this Mac's build paths (/Users/<name>/…): keep them out of a copy
# that is handed out. Crash reports still name the app's own functions.
strip -S "$APP/Contents/MacOS/JumpHost"
cp Resources/Info.plist "$APP/Contents/"
# RELAY_URL=https://… bakes a default relay into the bundle (a copy for someone who uses that
# relay). Unset, the app only uses a relay configured on its own Mac.
if [ -n "${RELAY_URL:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :JumpRelayURL string $RELAY_URL" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Resources"
ditto Resources/web "$APP/Contents/Resources/web"
ditto "$BIN/WebRTC.framework" "$APP/Contents/Frameworks/WebRTC.framework"

# Identity order: $SIGN_ID, an Apple Development cert (Xcode + Apple ID), a self-signed
# "Jump Host Dev" code-signing cert (Keychain Access), then ad-hoc.
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [ -z "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Jump Host Dev"'; then
  SIGN_ID="Jump Host Dev"
fi
SIGN_ID="${SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/WebRTC.framework"
codesign --force --sign "$SIGN_ID" --identifier com.jihun.jumphost "$APP"

if [ "$SIGN_ID" = "-" ]; then
  echo "Signed ad-hoc: macOS will ask for Screen Recording / Accessibility again after each rebuild."
else
  echo "Signed with: $SIGN_ID"
fi
echo "Built $APP"

# ./build.sh install  -> copy to ~/Applications (a fixed path for the permission lists) and relaunch.
if [ "${1:-}" = "install" ]; then
  pkill -x JumpHost 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/JumpHost.app"
  ditto "$APP" "$HOME/Applications/JumpHost.app"
  open "$HOME/Applications/JumpHost.app"
  echo "Installed and launched ~/Applications/JumpHost.app"
fi
