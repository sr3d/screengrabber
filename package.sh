#!/bin/bash
# Builds ScreenGrabber.app and packages it into a distributable .dmg with a
# drag-to-Applications shortcut and the app icon as the volume / file icon.
# Everything lands in dist/.
#
#   ./package.sh                      # native arch
#   ARCHS="arm64 x86_64" ./package.sh # universal (needs full Xcode)
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

DIST="dist"
APP="$DIST/ScreenGrabber.app"
ICON="Icon/AppIcon.icns"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="$DIST/ScreenGrabber-${VERSION}.dmg"

echo "==> Staging DMG contents…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ICON" "$STAGE/.VolumeIcon.icns"   # Finder uses this once the volume's icon bit is set

echo "==> Building disk image…"
RW="$(mktemp -u).dmg"
hdiutil create -volname "ScreenGrabber" -srcfolder "$STAGE" \
    -fs HFS+ -format UDRW -ov "$RW" >/dev/null

# Mount read-write, flag the volume as having a custom icon, then detach.
MOUNT="$(hdiutil attach "$RW" -nobrowse -noverify -readwrite | grep -o '/Volumes/.*' | head -1)"
SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" >/dev/null

echo "==> Compressing ${DMG}…"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RW"

# Give the .dmg file itself the app icon in Finder.
swift Icon/set-file-icon.swift "$ICON" "$DMG" || echo "    (warning: could not set .dmg file icon)"

echo "==> Done: $(pwd)/$DMG"
