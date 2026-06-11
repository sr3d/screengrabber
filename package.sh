#!/bin/bash
# Builds ScreenGrabber.app and packages it into a distributable .dmg with a
# drag-to-Applications shortcut. Output: ScreenGrabber-<version>.dmg
#
#   ./package.sh                      # native arch
#   ARCHS="arm64 x86_64" ./package.sh # universal (needs full Xcode)
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

APP="ScreenGrabber.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="ScreenGrabber-${VERSION}.dmg"

echo "==> Staging DMG contents…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating ${DMG}…"
rm -f "$DMG"
hdiutil create -volname "ScreenGrabber" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> Done: $(pwd)/$DMG"
