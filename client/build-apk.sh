#!/bin/bash
# Builds the Android APK to hand out: ../dist/wherever-android-<version>.apk (arm64).
#
# Flutter writes the absolute path of the generated plugin registrant into libapp.so
# (file:///Users/<name>/…/.dart_tool/flutter_build/dart_plugin_registrant.dart), so a build made
# in the home folder carries the user name. This copies the project to a neutral folder and
# builds there, then checks the APK for the home path.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' pubspec.yaml)"
WORK="${JUMP_BUILD_DIR:-/Users/Shared/jump-build}/client"
OUT="$(cd .. && pwd)/dist/wherever-android-$VERSION.apk"

mkdir -p "$WORK" "$(dirname "$OUT")"
rsync -a --delete --exclude build --exclude .dart_tool --exclude .gradle --exclude '.idea' ./ "$WORK/"
# APP_VERSION: shown on the connect page and in settings (lib/src/app_version.dart).
(cd "$WORK" && flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define=APP_VERSION="$VERSION")
cp "$WORK/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" "$OUT"

if unzip -p "$OUT" 2>/dev/null | LC_ALL=C grep -a -q -e "$HOME" -e "/Users/$USER"; then
  echo "✗ $OUT still contains the home folder path" >&2
  exit 1
fi
echo "Built $OUT ($(du -h "$OUT" | cut -f1)), no home path inside"
