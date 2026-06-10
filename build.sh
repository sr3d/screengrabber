#!/bin/bash
# Builds ScreenGrabber.app from the SwiftPM executable. No Xcode required —
# just Command Line Tools (swift build) plus a hand-assembled .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Compiling (release)…"
swift build -c release

APP="ScreenGrabber.app"
BIN=".build/release/screengrabber"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/screengrabber"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so the app has a stable identity for TCC (Screen Recording)
# permission persistence across rebuilds.
echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
