# ScreenGrabber

A fast, no-friction screenshot grabber + annotator for macOS. Hit a hotkey,
drag a region, mark it up (arrows, rectangles, circles, blur/black-box masks),
then **Copy** straight to the clipboard and paste into Slack — no Finder detour.

It runs as a menu-bar background app (no Dock icon) and reuses the native
`screencapture` crosshair selector, so the region-drag feels exactly like the
built-in ⇧⌘4.

## Build

Requires the Xcode Command Line Tools (Swift 5.9+). No full Xcode needed.

```bash
./build.sh
open ScreenGrabber.app
```

`build.sh` compiles the SwiftPM executable, assembles `ScreenGrabber.app`, and
ad-hoc signs it (so the Screen Recording permission sticks across rebuilds).

## First-run setup

1. **Launch** `ScreenGrabber.app`. A ✂️ scissors icon appears in the menu bar.
2. **Grant Screen Recording.** The first capture triggers the macOS permission
   prompt → enable ScreenGrabber under *System Settings ▸ Privacy & Security ▸
   Screen Recording*, then relaunch the app.
3. **Free up ⇧⌘4 (the hotkey).** macOS owns ⇧⌘4 by default. Turn it off at
   *System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Screenshots* →
   uncheck **"Save picture of selected area as a file"**. ScreenGrabber then
   owns ⇧⌘4. (You can still capture via the menu-bar icon regardless.)

## Use

- Press **⇧⌘4** (or menu-bar icon ▸ *Capture Region*) and drag a region.
- The editor opens. Pick a tool, color, and stroke width in the toolbar:
  - **Arrow / Rect / Circle** — annotate
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

## Layout

| File | Role |
|------|------|
| `Sources/screengrabber/main.swift` | App bootstrap, menu-bar item, ⇧⌘4 wiring |
| `HotKeyCenter.swift` | Carbon global hotkey (no Accessibility permission needed) |
| `CaptureController.swift` | Runs `screencapture -i`, returns a CGImage |
| `CanvasView.swift` | Drawing surface, annotation model, pixelate/box masking, export |
| `EditorWindowController.swift` | Toolbar + canvas window, Save/Copy |

## Changing the hotkey

Edit the `register(keyCode:modifiers:)` call in `main.swift`. Key codes are
Carbon virtual key codes (`kVK_ANSI_*`); modifiers combine `cmdKey`, `shiftKey`,
`optionKey`, `controlKey`.
