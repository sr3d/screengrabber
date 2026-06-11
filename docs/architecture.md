# Architecture overview

ScreenGrabber is a small AppKit (macOS native) app written in Swift, built with
Swift Package Manager (no Xcode project file — see [`Package.swift`](../Package.swift)).
It has **no third-party dependencies**; everything is Apple's own frameworks
(`AppKit`, `CoreGraphics`, `CoreText`, `Carbon`).

This page is the map. The detailed editor logic gets its own page:
[The Canvas editor, in depth](canvas-editor.md).

## The one-sentence summary

> Press a hotkey → the system crosshair selector grabs a region → we get a
> `CGImage` → optionally copy/save it → open an editor window where you draw
> annotations → flatten image + annotations into a new `CGImage` → copy or save.

## The end-to-end flow

Here's the journey of a single screenshot, with the file responsible for each step:

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. App launches as a menu-bar accessory (no Dock icon)                │
│    main.swift  →  AppDelegate.applicationDidFinishLaunching            │
│    - installs the ⇧⌘4 global hotkey  (HotKeyCenter)                    │
│    - adds the ✂️ menu-bar item + menu                                  │
└──────────────────────────────────────────────────────────────────────┘
                              │  user presses ⇧⌘4 (or clicks the menu)
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 2. Capture a region                                                   │
│    CaptureController.beginCapture                                     │
│    - shells out to /usr/sbin/screencapture -i -o <tmpfile>           │
│    - the OS draws the familiar crosshair; user drags a region        │
│    - reads the temp PNG back into a CGImage, deletes the temp file   │
└──────────────────────────────────────────────────────────────────────┘
                              │  CGImage (full resolution), on the main thread
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 3. Side effects, per Settings                                        │
│    main.swift  →  AppDelegate.beginCapture's completion handler      │
│    - if "copy on capture":  copyImageToClipboard(image) + Toast      │
│    - if "auto-save":        write the raw PNG to disk now            │
│    - if "show editor":      open the editor window                   │
└──────────────────────────────────────────────────────────────────────┘
                              │  CGImage + optional autoSaveURL
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 4. Edit                                                              │
│    EditorWindowController   (toolbar + window chrome)                │
│      └─ CanvasView          (the drawing surface — see deep dive)    │
│    - user draws/moves/resizes shapes, types text                    │
└──────────────────────────────────────────────────────────────────────┘
                              │  on Save / Copy / window-close
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 5. Flatten + output                                                  │
│    CanvasView.compositeImage()  → a new full-res CGImage             │
│    - Save…  → NSSavePanel → write PNG                                │
│    - Copy   → clipboard                                              │
│    - close  → overwrite the auto-saved file with the annotated one   │
└──────────────────────────────────────────────────────────────────────┘
```

## The files

| File | Role | Lines |
|------|------|------:|
| [`main.swift`](../Sources/screengrabber/main.swift) | App entry point. The `AppDelegate` owns the menu-bar item, wires the hotkey, draws the menu-bar glyph, runs the capture→side-effects→editor sequence, and manages the [activation policy](#activation-policy-the-dock-icon-trick). | ~190 |
| [`HotKeyCenter.swift`](../Sources/screengrabber/HotKeyCenter.swift) | Registers a **global** hotkey via the old Carbon Event Manager. Carbon is used because it needs **no Accessibility permission** (an `NSEvent` global monitor would). A singleton dispatches key presses to handlers by id. | ~60 |
| [`CaptureController.swift`](../Sources/screengrabber/CaptureController.swift) | Runs the system `screencapture` binary for interactive region selection on a background queue, then loads the result into a `CGImage`. Reusing the OS selector means we don't reinvent the drag UI *and* the Screen Recording permission prompt is shown natively. | ~40 |
| [`CanvasView.swift`](../Sources/screengrabber/CanvasView.swift) | **The editor core.** The annotation data model, mouse/keyboard handling, drawing, selection, control-point resizing, text editing, pixelation, and export. [Its own deep-dive page.](canvas-editor.md) | ~680 |
| [`EditorWindowController.swift`](../Sources/screengrabber/EditorWindowController.swift) | Builds the editor window: the toolbar (tool picker, color well, width slider, text-size popup, Undo/Clear/Save/Copy buttons) and hosts the `CanvasView`. Translates toolbar actions into calls on the canvas. | ~225 |
| [`Preferences.swift`](../Sources/screengrabber/Preferences.swift) | Settings persisted in `UserDefaults` (save folder, filename, the three "on capture" toggles, launch-at-login). Also the shared `writePNG` / `copyImageToClipboard` helpers. | ~130 |
| [`PreferencesWindowController.swift`](../Sources/screengrabber/PreferencesWindowController.swift) | The Settings window UI. | ~125 |
| [`Toast.swift`](../Sources/screengrabber/Toast.swift) | The small "Screenshot copied" floating notification. | ~80 |

## Key design decisions (and why)

**Menu-bar accessory, not a normal app.** The app launches with
`setActivationPolicy(.accessory)` ([`main.swift:192`](../Sources/screengrabber/main.swift)),
so it has no Dock icon and doesn't steal focus. It only becomes a "regular" app
*while an editor window is open*, then drops back. This is the
[activation-policy trick](#activation-policy-the-dock-icon-trick) below.

**Reuse the system screenshot tool.** Rather than building our own region selector
and requesting Screen Recording ourselves, `CaptureController` shells out to
`/usr/sbin/screencapture -i`. The drag feels exactly like ⇧⌘4 because it *is* ⇧⌘4's
selector, and macOS presents its own permission prompt.

**Carbon for the hotkey.** A global hotkey that fires while another app is focused
normally needs Accessibility permission. The Carbon `RegisterEventHotKey` API is an
exception — it works permission-free, which keeps install friction near zero.

**Annotations as plain data, drawn immediate-mode.** The editor does *not* keep a
tree of shape view objects. It keeps an array of `Annotation` *values* and repaints
them all on every frame. This is the single most important design choice and it's
explained fully in the [editor deep dive](canvas-editor.md#why-immediate-mode).

**One render path for screen and export.** The exact same `render(_:into:)` function
draws to the screen and to the off-screen bitmap used for export. The only
difference is a coordinate transform set up before the loop. See
[coordinate systems](canvas-editor.md#the-two-coordinate-systems).

## Activation policy: the Dock-icon trick

A subtle but important bit of `main.swift`:

- At launch: `.accessory` → menu-bar only, no Dock icon, never steals focus.
- When an editor opens (`openEditor`): switch to `.regular` and `activate`, so the
  window appears in the Dock and ⌘-Tab switcher and can take keyboard focus.
- When the **last** editor closes (`updateActivationPolicy`): back to `.accessory`.

This is why the app feels invisible until you actually capture something, yet the
editor behaves like a normal focusable window while it's open.

## Where to go next

- To understand drawing, selection, and editing → **[The Canvas editor, in
  depth](canvas-editor.md)**.
- To add a feature → **[Adding shapes & extending editing](adding-shapes.md)**.
