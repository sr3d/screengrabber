#!/bin/bash
# Builds ScreenGrabber.app from the SwiftPM executable. No Xcode required —
# just Command Line Tools (swift build) plus a hand-assembled .app bundle.
#
# By default this builds for the host architecture only. To build a universal
# binary (arm64 + x86_64, e.g. for a release) set ARCHS — this requires a full
# Xcode install, not just the Command Line Tools:
#
#     ARCHS="arm64 x86_64" ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

# Translate ARCHS ("arm64 x86_64") into repeated --arch flags. Empty = native.
ARCH_FLAGS=""
for a in ${ARCHS:-}; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done

echo "==> Compiling (release)…"
swift build -c release $ARCH_FLAGS

APP="dist/ScreenGrabber.app"
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/screengrabber"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/screengrabber"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so the app has a stable identity for TCC (Screen Recording)
# permission persistence across rebuilds.
echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
