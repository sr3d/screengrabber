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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/screengrabber"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Embed Sparkle (auto-update). `swift build` links against the SPM binary
# artifact but doesn't copy it into a bundle, so we do it here. The macОS slice
# of the XCFramework is already universal (arm64 + x86_64). The executable's
# rpath (@executable_path/../Frameworks, set in Package.swift) finds it here.
echo "==> Embedding Sparkle.framework…"
SPARKLE_FW="$(find .build/artifacts -path '*macos*/Sparkle.framework' -type d | head -1)"
if [ -z "$SPARKLE_FW" ]; then
    echo "!! Sparkle.framework not found — run 'swift package resolve' first." >&2
    exit 1
fi
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# Ad-hoc sign so the app has a valid (if unverified) code signature. NOTE: an
# ad-hoc signature is NOT stable across rebuilds — its identity is the binary's
# cdhash, which changes every build. So macOS sees each rebuild as a new app and
# re-prompts for Screen Recording. To keep the grant after a rebuild, reset and
# re-grant once:  tccutil reset ScreenCapture com.sr3d.screengrabber
echo "==> Ad-hoc signing…"
# Sign inside-out: Sparkle's nested helpers (XPC services, Autoupdate, the
# Updater.app) must be signed before the framework, and the framework before the
# app. (`codesign --deep` is unreliable for nested XPC bundles, so we're
# explicit.) Ad-hoc is fine here — update integrity is guaranteed by Sparkle's
# EdDSA signature, not the code signature.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    VB="$FW/Versions/B"
    codesign --force --sign - "$VB/XPCServices/Downloader.xpc"
    codesign --force --sign - "$VB/XPCServices/Installer.xpc"
    codesign --force --sign - "$VB/Autoupdate"
    codesign --force --sign - "$VB/Updater.app"
    codesign --force --sign - "$FW"
fi
codesign --force --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
