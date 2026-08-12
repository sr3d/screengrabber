# ScreenGrabber — Work Status

_Progress notes for the current work session. Not intended to be committed with feature code — delete or ignore before merging if you don't want it in the repo._

## Branch

`feat/sparkle-and-file-actions` (based on `main`).

### Already committed on this branch
- `0df100d` Add Copy File and Reveal File to the editor
- `dc0a0fc` Add Sparkle auto-update

### Uncommitted working-tree changes (built & verified, not yet committed)
- `Sources/screengrabber/CanvasView.swift` — crop mode + snapshot-based undo
- `Sources/screengrabber/EditorWindowController.swift` — Crop button, window resize, recents hooks
- `Sources/screengrabber/MenuBarDropView.swift` — **new** menu-bar drag-and-drop overlay
- `Sources/screengrabber/main.swift` — drop wiring, Recent Screenshots menu + thumbnails, updater error diagnostics
- `Sources/screengrabber/Preferences.swift` — recent-files store
- `Info.plist` — `SUFeedURL` set to custom domain
- `scripts/update-appcast.sh` — download-url-prefix set to custom domain
- `README.md` — docs for all of the above

Suggested commit grouping when ready: (1) crop tool, (2) menu-bar drag-drop, (3) recent-screenshots menu, (4) update error-reporting + feed-domain fix.

## Features implemented this session

1. **Copy File / Reveal File** (committed) — editor toolbar; Copy File = ⇧⌘C copies the file URL; Save… chevron → Reveal File in Finder.
2. **Sparkle auto-update** (committed) — updater controller, Check for Updates… menu item, Settings toggle, EdDSA-signed appcast published to `gh-pages` by CI. Ad-hoc signing (no Developer ID) — integrity via EdDSA.
3. **Crop tool** (uncommitted) — Crop button → drag region → Return applies / Esc cancels; ⌘Z undoes. Undo generalized to full-state snapshots (draws, deletes, Clear, crop all undo in order). Window refits to cropped aspect.
4. **Drag image onto menu-bar icon** (uncommitted) — `MenuBarDropView` overlay accepts dropped image files → opens editor; also pops the status menu on click.
5. **Recent Screenshots menu** (uncommitted) — menu-bar submenu, last 20 files with thumbnails, click to reopen; backed by recents store in `Preferences`. Records on capture, Save…, Copy/Reveal File, editor close, and drop.
6. **Update error diagnostics** (uncommitted) — `SPUUpdaterDelegate` logs + shows full `NSError` chain (domain/code/message/failing URL/underlying), with Copy Details button.

## Build status
`./build.sh` succeeds; bundle passes `codesign --verify --deep --strict`. App NOT launched (would take over ⇧⌘4 / add menu-bar icon) — interactive features (crop drag, Finder drop, menu thumbnails, live update) still need manual testing by running `dist/ScreenGrabber.app`.

## Sparkle / auto-update — remaining MANUAL setup (blocks "Check for Updates")
The current update failure is NOT a code bug: the appcast feed 404s because Pages isn't serving yet.

1. **Enable GitHub Pages**: repo Settings ▸ Pages ▸ Source = `gh-pages` branch / root. Verify `https://alexle.net/screengrabber/` serves the placeholder page.
2. **Add Actions secret** `SPARKLE_ED_PRIVATE_KEY` = `0ob+ndgVbKk1zRexMOud0mOZUgWIrV1XpWGtiy2NxTw=` (also in login Keychain; re-export via `generate_keys -x`).
3. **Cut a release**: bump `CFBundleShortVersionString` (+`CFBundleVersion`) in `Info.plist`, then `git tag vX.Y.Z && git push origin vX.Y.Z`. CI signs the DMG and publishes `appcast.xml` to `gh-pages`.

Verify after: `curl -sSI https://alexle.net/screengrabber/appcast.xml` → 200.

## Key facts
- EdDSA **public key** (in Info.plist `SUPublicEDKey`): `HIFetPDyPgY4zMZs3pNCpBpS9fhOa0jGjZl8xtdeHyo=`
- **Feed URL**: `https://alexle.net/screengrabber/appcast.xml` (custom domain; `sr3d.github.io` 301-redirects to `alexle.net`)
- `gh-pages` branch exists on origin with `index.html` + `.nojekyll` (pushed this session).
- First Sparkle release must be installed manually; pre-Sparkle 1.0.1 installs won't auto-update to it.

## Open decisions / next steps
- Commit & push the uncommitted work? (grouping suggested above.) User has not yet confirmed for this batch.
- Manual testing of crop / drag-drop / recents / live update.
