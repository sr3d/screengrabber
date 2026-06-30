#!/bin/bash
# Updates the Sparkle appcast after a release.
#
# Sparkle clients poll SUFeedURL (see Info.plist) for an appcast.xml listing the
# latest version + an EdDSA signature of the download. We host both the appcast
# and the .dmg files on the `gh-pages` branch so every download lives under one
# constant URL prefix (GitHub *Release* asset URLs embed the per-version tag, so
# Sparkle's single --download-url-prefix can't target them).
#
# Each run: drop the freshly built .dmg onto gh-pages and regenerate the appcast
# from *all* the .dmgs there, so the feed always lists the full version history.
#
# Required env:
#   GH_TOKEN                 token with contents:write (github.token in CI)
#   SPARKLE_ED_PRIVATE_KEY   the EdDSA private key (contents of the file from
#                            `generate_keys -x`), stored as a GitHub Actions secret
#   GITHUB_REPOSITORY        owner/repo (provided by Actions)
#   GITHUB_REF_NAME          the tag, e.g. v1.1.0 (provided by Actions)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GH_TOKEN:?need GH_TOKEN}"
: "${SPARKLE_ED_PRIVATE_KEY:?need SPARKLE_ED_PRIVATE_KEY}"
: "${GITHUB_REPOSITORY:?need GITHUB_REPOSITORY}"

PAGES_URL="https://$(echo "$GITHUB_REPOSITORY" | cut -d/ -f1).github.io/$(echo "$GITHUB_REPOSITORY" | cut -d/ -f2)/"
REPO_URL="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# generate_appcast ships inside Sparkle's SPM binary artifact (downloaded by the
# earlier `swift build`). Make sure it's present, then locate it.
swift package resolve >/dev/null 2>&1 || true
GEN="$(find .build/artifacts -name generate_appcast -type f | head -1)"
if [ -z "$GEN" ]; then echo "!! generate_appcast not found" >&2; exit 1; fi

# Check out the gh-pages branch (or start an empty one on the first release).
PAGES_DIR="$(mktemp -d)"
if ! git clone --branch gh-pages --single-branch "$REPO_URL" "$PAGES_DIR" 2>/dev/null; then
    echo "==> gh-pages doesn't exist yet — creating it"
    git clone "$REPO_URL" "$PAGES_DIR"
    git -C "$PAGES_DIR" checkout --orphan gh-pages
    git -C "$PAGES_DIR" rm -rf . >/dev/null 2>&1 || true
fi

echo "==> Adding $(ls dist/ScreenGrabber-*.dmg) to gh-pages"
cp dist/ScreenGrabber-*.dmg "$PAGES_DIR/"

echo "==> Regenerating appcast.xml (signing with EdDSA key)…"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GEN" "$PAGES_DIR" \
    --ed-key-file - \
    --download-url-prefix "$PAGES_URL" \
    --link "https://github.com/${GITHUB_REPOSITORY}"

echo "==> Publishing to gh-pages…"
git -C "$PAGES_DIR" add -A
git -C "$PAGES_DIR" -c user.email="github-actions[bot]@users.noreply.github.com" \
    -c user.name="github-actions[bot]" \
    commit -m "Update appcast for ${GITHUB_REF_NAME:-release}"
git -C "$PAGES_DIR" push origin gh-pages

echo "==> Appcast published: ${PAGES_URL}appcast.xml"
