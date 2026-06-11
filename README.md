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
- **Undo** (⌘Z), **Clear**, **Save…** (⌘S, writes PNG), **Copy** (⌘C, to clipboard).
- Paste into Slack with ⌘V.

### Tool shortcuts

| Key | Tool | | Key | Tool |
|-----|------|-|-----|------|
| `1` | Select | | `5` | Circle |
| `2` | Arrow | | `6` | Blur |
| `3` | Line | | `7` | Box |
| `4` | Rectangle | | `T` | Text |

The drawing controls are grouped together on the left of the toolbar: the tool
buttons, the **`Aa` dropdown** (text size), then the color well and stroke-width
slider. File actions (Undo / Clear / Save / Copy) sit on the right.

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

GitHub Actions builds a universal `.dmg` on a macOS runner and publishes it to a new
GitHub Release with auto-generated notes.

### Layout

| File | Role |
|------|------|
| `Sources/screengrabber/main.swift` | App bootstrap, menu-bar item, ⇧⌘4 wiring, About, auto-save |
| `HotKeyCenter.swift` | Carbon global hotkey (no Accessibility permission needed) |
| `CaptureController.swift` | Runs `screencapture -i`, returns a CGImage |
| `CanvasView.swift` | Drawing surface, annotation model, selection/handles, tool shortcuts, export — see the [deep dive](docs/canvas-editor.md) |
| `EditorWindowController.swift` | Toolbar + canvas window, text size, Save/Copy |
| `Preferences.swift` | Settings (UserDefaults) + PNG writing |
| `PreferencesWindowController.swift` | Settings window |
| `Icon/generate-icon.swift` | Programmatic app-icon generator |

### Changing the hotkey

Edit the `register(keyCode:modifiers:)` call in `main.swift`. Key codes are
Carbon virtual key codes (`kVK_ANSI_*`); modifiers combine `cmdKey`, `shiftKey`,
`optionKey`, `controlKey`.

## License

[MIT](LICENSE) © sr3d
