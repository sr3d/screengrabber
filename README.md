<div align="center">

<img src="Icon/AppIcon-1024.png" alt="ScreenGrabber icon" width="200" height="200">

# ScreenGrabber

### A fast, no-friction screenshot grabber + annotator for macOS.

[![CI](https://github.com/sr3d/screengrabber/actions/workflows/ci.yml/badge.svg)](https://github.com/sr3d/screengrabber/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/sr3d/screengrabber)](https://github.com/sr3d/screengrabber/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)

</div>

Hit a hotkey, drag a region, mark it up (arrows, rectangles, circles, blur/black-box
masks), then **Copy** straight to the clipboard and paste into Slack — no Finder detour.

It runs as a menu-bar background app (no Dock icon) and reuses the native
`screencapture` crosshair selector, so the region-drag feels exactly like the
built-in ⇧⌘4.

## Download & Install

1. **Download** the latest `ScreenGrabber-*.dmg` from the
   [**Releases**](https://github.com/sr3d/screengrabber/releases/latest) page.
2. **Open the `.dmg`** and drag **ScreenGrabber** into your **Applications** folder.
3. **First launch — get past Gatekeeper.** ScreenGrabber is open-source but not
   signed with a paid Apple Developer ID, so macOS blocks it the first time.
   Pick whichever you prefer:

   - **GUI:** double-click the app, dismiss the warning, then go to
     **System Settings ▸ Privacy & Security**, scroll down, and click
     **"Open Anyway"**. Confirm once.
   - **Terminal (one command):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/ScreenGrabber.app
     ```
     then open the app normally.

> Requires **macOS 13 (Ventura) or later**. The release build is a universal
> binary — it runs natively on both Apple Silicon and Intel Macs.

Prefer to build it yourself? See [Development](#development). Curious how it works
inside? See the [**Developer docs**](docs/README.md).

## First-run setup

<div align="center">

<img src="docs/ScreenGrabber%20Menubar.png" alt="ScreenGrabber menu-bar dropdown" width="320">

</div>

1. **Launch** ScreenGrabber. A ✂️ scissors icon appears in the menu bar.
2. **Grant Screen Recording.** The first capture triggers the macOS permission
   prompt → enable ScreenGrabber under *System Settings ▸ Privacy & Security ▸
   Screen Recording*, then relaunch the app.

   > **Permission prompt keeps coming back even after you allow it?** That means
   > the quarantine flag is still on the app, so macOS runs it from a random
   > location each launch and the grant never sticks. Strip it once (the same
   > command as the Gatekeeper step above) and the permission will hold:
   > ```bash
   > xattr -dr com.apple.quarantine /Applications/ScreenGrabber.app
   > tccutil reset ScreenCapture com.sr3d.screengrabber   # clears the stale grant
   > ```
3. **The ⇧⌘4 hotkey just works.** While ScreenGrabber is running it takes over
   ⇧⌘4 automatically (macOS normally owns it), and hands it back to the built-in
   screenshot tool when you quit. No System Settings changes needed. (You can
   always capture via the menu-bar icon too.)

   > On a macOS version where ScreenGrabber can't toggle the system shortcut,
   > free up ⇧⌘4 yourself at *System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸
   > Screenshots* → uncheck **"Save picture of selected area as a file"**.

## Use

- Press **⇧⌘4** (or menu-bar icon ▸ *Capture Region*) and drag a region.
- Already have an image? Menu-bar icon ▸ **Open Image…** (⌘O in the editor) opens
  one — or several — straight into the editor, no capture needed. You can also
  drag image files onto the menu-bar icon.
- Or **drag an image file onto the menu-bar icon** to open it in the editor.
- The menu-bar icon ▸ **Recent Screenshots** lists your last 20 captures with thumbnails — click one to reopen it.
- The editor opens. Pick a tool, color, and stroke width in the toolbar:
  - **Arrow / Line / Rect / Circle** — annotate
  - **Blur** — pixelate a region (obscure tokens, emails, faces)
  - **Box** — solid black redaction bar
  - **Text** — click a point and type; **Return** adds a new line, **Esc** or **⌘Return** finishes
- After you draw a shape, the editor drops into **Select** mode automatically so you can adjust it right away.
- **Select** mode — adjust existing shapes:
  - Click a shape to select it; drag its **body to move**, drag a **handle to resize**
    (arrows have two endpoint handles; boxes/circles have eight edge & corner handles).
  - Change the color or stroke width while a shape is selected to restyle it.
  - **Double-click** a text box to re-edit it.
  - **Delete/Backspace** removes the selected shape.
- **Crop** — click **Crop**, drag the region to keep, then **Return** to apply or **Esc** to cancel. Undoable with ⌘Z.
- **Select text on the image**, like Preview — in Select mode (`1`), hover over
  text in the screenshot and the pointer becomes an I-beam; drag to select, ⌘C to
  copy, right-click for Copy / Look Up. Everywhere else the drawing and selection
  tools behave exactly as before, and a shape drawn over text still takes the
  click. **Select Text** (⇧⌘L) forces the mode on for the whole image; **Esc**
  leaves it. Needs an Apple silicon Mac — on Intel the button is disabled and OCR
  below does the job.
- **OCR** (⇧⌘T) — click the **OCR** button to read the text out of the screenshot.
  It opens an **Extracted Text** panel you can select and copy from, or grab all
  at once with **Copy All**. Press **⌘F** to search it (⌘G / ⇧⌘G for next and
  previous match). The text is **editable**, so you can fix anything OCR got wrong
  (or trim it down) before copying — Copy All takes your edits.
  Recognition is on-device (Apple's Vision framework) —
  nothing is uploaded. It runs on what's currently visible, so it follows a crop
  and won't bring back text you blurred or boxed out.
- **Undo** (⌘Z), **Clear**, **Save…** (⌘S, writes PNG), **Copy** (⌘C, to clipboard).
- **Copy File** (⇧⌘C) — copies the image *file* (not the pixels) so you can ⌘V it into another folder in Finder.
- The **Save…** chevron drops a **Reveal File in Finder** option (opens a Finder window with the file selected).
- Paste into Slack with ⌘V.

### Tool shortcuts

| Key | Tool | | Key | Tool |
|-----|------|-|-----|------|
| `1` | Select | | `5` | Circle |
| `2` | Arrow | | `6` | Blur |
| `3` | Line | | `7` | Box |
| `4` | Rectangle | | `T` | Text |

The drawing controls are grouped together on the left of the toolbar: the tool
buttons, the **Crop**, **OCR** and **Select Text** buttons, the **`Aa` dropdown**
(text size), then the color well and stroke-width slider. File actions (Undo /
Clear / Save / Copy / Copy File) sit on the right.

## Settings (⌘,)

Open from the menu-bar icon ▸ *Settings…* (or **⌘,** in the editor):

<div align="center">

<img src="docs/ScreenGrabber%20Preferences.png" alt="ScreenGrabber Settings window" width="560">

</div>

- **Save location** — defaults to the macOS screenshot folder (Desktop unless you've
  changed it); choose any folder, or reset to default.
- **Filename** — defaults to the macOS convention (`Screenshot <date> at <time>.png`);
  customize the prefix.
- **On capture** — what happens the moment you finish dragging a region:
  - **Save a file automatically** (default **on**) — writes a PNG immediately, then
    updates that same file with your annotations when you close the editor.
  - **Copy to the clipboard automatically** (default **on**) — the screenshot is
    paste-ready right away (a "Screenshot copied to clipboard" toast confirms it), so
    you can capture and ⌘V into Slack without opening the editor.
  - **Show the editor after a screenshot** (default **on**) — turn it off for a
    streamlined capture-only workflow (just save and/or copy, no editor window).
- **Default tool** (default **Arrow**) — which tool is active when the editor opens.
  Pick any tool, or **Select** to open in selection mode (handy if you mostly tweak
  existing shapes rather than draw new ones).
- **Start ScreenGrabber at login** (default **off**) — registers the app as a macOS
  login item so it's always in your menu bar after a restart.
- **Check for updates automatically** — lets the app check for and install new
  versions in the background via Sparkle. You can also run a check any time from
  the menu-bar icon ▸ *Check for Updates…*.

## Development

> **New to the code?** The [**Developer docs**](docs/README.md) explain how the app
> works internally — start with the [architecture overview](docs/architecture.md),
> then the [Canvas editor deep dive](docs/canvas-editor.md) (the annotation engine),
> and [how to add shapes](docs/adding-shapes.md). Written for readers new to Swift.

Requires the **Xcode Command Line Tools** (Swift 5.9+). No full Xcode needed for a
local build.

```bash
./build.sh          # compile + assemble + ad-hoc sign → dist/ScreenGrabber.app
open dist/ScreenGrabber.app
```

`build.sh` compiles the SwiftPM executable, assembles `dist/ScreenGrabber.app`,
copies in the icon, and ad-hoc signs it (so the Screen Recording permission sticks
across rebuilds). All build output lands in `dist/` (git-ignored). It builds for
your host architecture by default; pass `ARCHS` for a universal binary (needs a
full Xcode install):

```bash
ARCHS="arm64 x86_64" ./build.sh
```

An ad-hoc signature isn't stable across rebuilds, so macOS treats each build as a
new app and re-prompts for Screen Recording. To exercise the editor without
granting it again every time, skip the capture entirely: menu-bar icon ▸
**Open Image…** (or ⌘O in the editor) loads any image straight into the editor.

### Packaging a `.dmg`

```bash
./package.sh                        # native-arch .dmg
ARCHS="arm64 x86_64" ./package.sh   # universal .dmg (needs full Xcode)
```

Produces `dist/ScreenGrabber-<version>.dmg` — with a drag-to-Applications shortcut
and the app icon as the volume and file icon.

### The app icon

The icon is generated programmatically — no image editor required:

```bash
swift Icon/generate-icon.swift      # regenerates Icon/AppIcon.icns + the master PNG
```

Edit `Icon/generate-icon.swift` to change the design, rerun it, then `./build.sh`.

### Cutting a release

Releases are automated by [`.github/workflows/release.yml`](.github/workflows/release.yml).
Bump `CFBundleShortVersionString` in `Info.plist`, then push a version tag:

```bash
git tag v1.0
git push origin v1.0
```

GitHub Actions builds a universal `.dmg` on a macOS runner, publishes it to a new
GitHub Release with auto-generated notes, and updates the Sparkle **appcast** so
existing installs auto-update (see below).

### Auto-update (Sparkle)

The app bundles [Sparkle](https://sparkle-project.org). It checks an *appcast*
feed (`SUFeedURL` in `Info.plist`) in the background and offers to download,
install, and relaunch new versions. Users can also trigger a check via the
menu-bar **Check for Updates…** item, and toggle automatic checks in **Settings**.

Updates are verified with an **EdDSA signature**, so they're secure even though
the app is only ad-hoc code-signed (no paid Apple Developer ID required). The
public key lives in `Info.plist` (`SUPublicEDKey`); the private key signs each
release in CI.

The appcast and the `.dmg` files are published to the **`gh-pages`** branch
(served at `https://alexle.net/screengrabber/appcast.xml`) by
[`scripts/update-appcast.sh`](scripts/update-appcast.sh), which signs the new
`.dmg` and regenerates `appcast.xml` from every `.dmg` on that branch.

**One-time setup** (already done for the keypair generated with `generate_keys`):

1. **Add the GitHub Actions secret** `SPARKLE_ED_PRIVATE_KEY` containing the
   EdDSA private key (Settings ▸ Secrets and variables ▸ Actions). Export it from
   your Keychain with Sparkle's `generate_keys -x privkey.txt` and paste the file
   contents.
2. **Enable GitHub Pages** for the repo with source = **`gh-pages`** branch
   (Settings ▸ Pages). The first tagged release creates the branch.

To rotate keys, run `generate_keys`, update `SUPublicEDKey` in `Info.plist`, and
replace the `SPARKLE_ED_PRIVATE_KEY` secret.

### Layout

| File | Role |
|------|------|
| `Sources/screengrabber/main.swift` | App bootstrap, menu-bar item, ⇧⌘4 wiring, About, auto-save |
| `HotKeyCenter.swift` | Carbon global hotkey (no Accessibility permission needed) |
| `CaptureController.swift` | Runs `screencapture -i`, returns a CGImage |
| `CanvasView.swift` | Drawing surface, annotation model, selection/handles, tool shortcuts, export — see the [deep dive](docs/canvas-editor.md) |
| `EditorWindowController.swift` | Toolbar + canvas window, text size, Save/Copy |
| `TextRecognizer.swift` | On-device OCR (Vision), sorted into reading order |
| `LiveTextOverlay.swift` | Preview-style text selection on the image (VisionKit) |
| `ExtractedTextWindowController.swift` | The Extracted Text panel behind the OCR button (⇧⌘T) |
| `Preferences.swift` | Settings (UserDefaults) + PNG writing |
| `PreferencesWindowController.swift` | Settings window |
| `Icon/generate-icon.swift` | Programmatic app-icon generator |

### Changing the hotkey

Edit the `register(keyCode:modifiers:)` call in `main.swift`. Key codes are
Carbon virtual key codes (`kVK_ANSI_*`); modifiers combine `cmdKey`, `shiftKey`,
`optionKey`, `controlKey`.

## License

[MIT](LICENSE) © sr3d
