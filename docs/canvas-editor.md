# The Canvas editor, in depth

Everything interesting about the editor lives in one file:
[`CanvasView.swift`](../Sources/screengrabber/CanvasView.swift) (~680 lines).
`CanvasView` is an `NSView` subclass — a rectangular region that can draw itself and
receive mouse and keyboard events. This page walks through it top to bottom.

> Line numbers below refer to `CanvasView.swift` as of this writing. They may drift
> as the file changes, but the section names (`// MARK: - …`) are stable anchors.

## Table of contents

1. [The annotation data model](#the-annotation-data-model)
2. [Why immediate-mode](#why-immediate-mode)
3. [The two coordinate systems](#the-two-coordinate-systems)
4. [State the view holds](#state-the-view-holds)
5. [Drawing a new shape (the mouse pipeline)](#drawing-a-new-shape-the-mouse-pipeline)
6. [Select mode: move & resize](#select-mode-move--resize)
7. [Hit-testing](#hit-testing)
8. [Control points (handles)](#control-points-handles)
9. [Resizing math](#resizing-math)
10. [Rendering each shape](#rendering-each-shape)
11. [Text: a special case](#text-a-special-case)
12. [The blur tool](#the-blur-tool)
13. [Keyboard handling](#keyboard-handling)
14. [Export / flattening](#export--flattening)
15. [The redraw cycle](#the-redraw-cycle)

---

## The annotation data model

The whole editor is built around one struct ([line 16](../Sources/screengrabber/CanvasView.swift#L16)):

```swift
struct Annotation {
    var tool: Tool          // which kind of shape
    var start: CGPoint      // first point (where the drag began / text anchor)
    var end: CGPoint        // second point (where the drag ended)
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""        // used by the .text tool only
    var fontSize: CGFloat = 28   // used by the .text tool only
}
```

Every shape — arrow, line, rectangle, ellipse, blur region, black box, text — is **one
`Annotation`**. The `tool` field (a `Tool` enum, [line 4](../Sources/screengrabber/CanvasView.swift#L4))
says which kind it is, and `start`/`end` define its geometry:

- For an **arrow**, `start` is the tail and `end` is the tip.
- For a **rectangle / ellipse / blur / box**, `start` and `end` are two opposite
  corners (in any order — the code normalizes them, see [`rect(for:)`](#rendering-each-shape)).
- For **text**, `start` is the top-left anchor of the text block; `end` is unused
  and the `text` + `fontSize` fields carry the content.

```swift
enum Tool: Int {
    case arrow = 0      // rawValue 0
    case rectangle      // 1
    case ellipse        // 2  (shown as "Circle" in the UI)
    case blur           // 3
    case box            // 4
    case text           // 5
    case line           // 6  (appended; see below)
}
```

The `rawValue` is **storage only** — new cases are *appended* so the numbers never
shift. The **display order** (toolbar segments, number-key shortcuts) is a separate,
explicit list, [`Tool.paletteOrder`](../Sources/screengrabber/CanvasView.swift), so a
tool can sit anywhere in the UI without touching its `rawValue`. That's why `.line`
appears right after Arrow in the toolbar despite being `rawValue 6`. A `Tool`
extension in the same file also carries each tool's `symbolName`, `displayName`, and a
stable `persistID` (used to store the "default tool" preference — never persist
`rawValue`). See [adding-shapes.md](adding-shapes.md) to add your own.

`Annotation` being a **`struct` (value type)** is deliberate. When you write
`annotations[i].start = …`, you're mutating a copy in place inside the array — no
shared references, no aliasing bugs. Undo is as simple as `annotations.removeLast()`.

The view holds them in a plain array ([line 48](../Sources/screengrabber/CanvasView.swift#L48)):

```swift
private(set) var annotations: [Annotation] = []   // committed shapes
private var draft: Annotation?                     // the one being dragged out now
```

`draft` is the shape currently being drawn but not yet committed; it's drawn on top
of the others and only appended to `annotations` on mouse-up.

## Why immediate-mode

There are **no `RectangleView`, `ArrowView`, … objects.** The canvas keeps a list of
`Annotation` data and, every time it needs to repaint, loops over the list and draws
each shape from scratch ([`draw(_:)`, line 491](../Sources/screengrabber/CanvasView.swift#L491)):

```swift
for a in annotations { render(a, into: ctx) }
if let d = draft { render(d, into: ctx) }
```

This is called **immediate-mode** (or "retained data, immediate drawing"), as
opposed to a **retained-mode** scene graph of view objects. The trade-off:

- ✅ Drastically simpler. Adding a shape = adding a `case` to a `switch`. No view
  lifecycle, no layout, no z-order bookkeeping (array order *is* z-order).
- ✅ The same draw code trivially renders at export resolution.
- ⚠️ Everything repaints on every change. For a screenshot annotator with a handful
  of shapes this is irrelevantly cheap; for thousands of objects it wouldn't be.

Internalize this: **shapes are data, drawing is a pure function of that data.** Most
features are "add a field" or "add a `case`."

## The two coordinate systems

This is the one genuinely tricky idea in the file, and it's worth slowing down for.

There are two coordinate spaces in play:

| | **Image-pixel space** | **View-point space** |
|---|---|---|
| Origin | bottom-left of the *image* | bottom-left of the *view* |
| Unit | one pixel of the full-res screenshot | one point of the on-screen view |
| Used for | **storing** all annotations | mouse events, drawing handles |
| Size | fixed (e.g. 2880×1800) | varies with the window |

**Why two?** The window can be any size — the image is shrunk ("letterboxed") to fit
with `min()` scaling and centered. But when you export, you want the annotations at
the screenshot's *full* resolution, crisp, regardless of how big the edit window
was. So the rule is:

> **Annotations are always stored in image-pixel space.** Convert to/from view space
> only at the edges (reading the mouse, drawing handles).

The plumbing, all near the top of the file:

- **`imageRect`** ([line 96](../Sources/screengrabber/CanvasView.swift#L96)) — the
  rectangle, in view points, where the image is actually painted (aspect-fit &
  centered). Recomputed each time from the current bounds, so it adapts to resizing.

- **`scale`** ([line 106](../Sources/screengrabber/CanvasView.swift#L106)) — image
  pixels per view point. If the image is drawn at half size, `scale = 0.5`.

- **`imagePoint(from event:)`** ([line 114](../Sources/screengrabber/CanvasView.swift#L114))
  — converts a mouse location into image-pixel space, then **clamps** it into the
  image bounds so you can't draw off the edge. Called at the start of every mouse
  handler.

- **`imageToView(_:)`** ([line 123](../Sources/screengrabber/CanvasView.swift#L123))
  — the inverse. Used when drawing selection handles, so they sit a **constant 8pt**
  on screen no matter the zoom.

The elegant payoff is in `draw(_:)` ([line 491](../Sources/screengrabber/CanvasView.swift#L491)).
Before looping over annotations, it transforms the graphics context once:

```swift
ctx.saveGState()
ctx.translateBy(x: r.minX, y: r.minY)   // move origin to the image's corner
ctx.scaleBy(x: scale, y: scale)         // scale image-px → view-px
for a in annotations { render(a, into: ctx) }   // render in IMAGE coordinates
ctx.restoreGState()
```

Inside `render`, the code works entirely in image pixels and never thinks about the
window size — the context transform handles it. At **export** time
([`compositeImage()`](#export--flattening)) there's no scaling at all (the bitmap
*is* full size), so the same `render` calls draw 1:1. **One render path, two
outputs.** This is the core reason the codebase stays small.

A coordinate gotcha worth flagging: Core Graphics uses a **bottom-left origin**, but
`CGImage.cropping` (used by the blur tool) uses a **top-left** origin, so the blur
code flips the y-axis explicitly. See [the blur tool](#the-blur-tool).

## State the view holds

Beyond `annotations` and `draft`, the view tracks the current tool settings and the
editing state ([lines 51–78](../Sources/screengrabber/CanvasView.swift#L51)):

```swift
var currentTool: Tool = .arrow      // the active draw tool
var currentColor: NSColor = .systemRed
var currentLineWidth: CGFloat = 4
var currentFontSize: CGFloat = 28

var selectMode = false { didSet { needsDisplay = true } }  // draw vs. select
private(set) var selectedIndex: Int?   // which annotation is selected (or nil)
private var editingTextIndex: Int?     // which text box is being typed into

// Transient drag bookkeeping:
private var activeDrag: Drag = .none   // .none / .drawing / .moving / .resizing
private var moveFrom, moveOrigStart, moveOrigEnd: CGPoint   // move anchors
```

`selectMode` uses a Swift **property observer** (`didSet`) to mark the view dirty
whenever it flips, so the selection chrome appears/disappears without the caller
having to remember to request a redraw.

The `Drag` enum ([line 41](../Sources/screengrabber/CanvasView.swift#L41)) is a tiny
state machine for what the current mouse-drag is doing:

```swift
private enum Drag {
    case none, drawing, moving, resizing(HandleRef)
}
```

Note `resizing` carries a `HandleRef` — *which* handle is being dragged. More on
that under [control points](#control-points-handles).

## Drawing a new shape (the mouse pipeline)

Three overrides implement the draw gesture: `mouseDown` → `mouseDragged` →
`mouseUp`.

**`mouseDown`** ([line 134](../Sources/screengrabber/CanvasView.swift#L134)):

```swift
let p = imagePoint(from: event)   // mouse → image pixels
commitTextEditing()               // any in-progress text edit ends first

if selectMode {
    // (double-click text re-enters editing; otherwise begin a selection)
    beginSelection(at: p)
} else if currentTool == .text {
    // place an empty text box and start typing
    …
} else {
    // start a draft shape; both endpoints at the click for now
    draft = Annotation(tool: currentTool, start: p, end: p, …)
    activeDrag = .drawing
}
needsDisplay = true
```

**`mouseDragged`** ([line 168](../Sources/screengrabber/CanvasView.swift#L168)) is a
`switch` on `activeDrag`. While `.drawing`, it just moves the draft's end point to
follow the cursor: `draft?.end = p`. (The `.moving` and `.resizing` branches are for
select mode, below.)

**`mouseUp`** ([line 187](../Sources/screengrabber/CanvasView.swift#L187)) commits:

```swift
if case .drawing = activeDrag, var d = draft {
    d.end = imagePoint(from: event)
    if hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 2 {  // ignore tiny clicks
        annotations.append(d)
        selectedIndex = annotations.count - 1
        didDraw = true
    }
}
draft = nil
activeDrag = .none
if didDraw { onDrawFinished?() }   // host flips the toolbar into Select mode
```

The `> 2` check throws away an accidental click that didn't really drag. The
`onDrawFinished` callback is how, right after you draw, the app auto-switches to
Select mode so you can immediately tweak the shape you just made (wired up in
[`EditorWindowController.swift:54`](../Sources/screengrabber/EditorWindowController.swift#L54)).

## Select mode: move & resize

When `selectMode` is on, a `mouseDown` calls **`beginSelection(at:)`**
([line 204](../Sources/screengrabber/CanvasView.swift#L204)), which decides what the
drag will do, in priority order:

```
1. Is the click on a HANDLE of the already-selected shape?  → .resizing(handle)
2. Else, is it on the BODY of some shape?                   → select it, .moving
3. Else (empty space)                                       → deselect
```

```swift
// 1. Handle of the current selection wins, even over other shapes underneath.
if let i = selectedIndex, i < annotations.count,
   let ref = handleHit(at: p, annotation: annotations[i]) {
    activeDrag = .resizing(ref)
    return
}
// 2. Otherwise grab the topmost shape under the cursor and prepare to move it.
if let i = bodyHit(at: p) {
    selectedIndex = i
    moveFrom = p
    moveOrigStart = annotations[i].start
    moveOrigEnd = annotations[i].end
    activeDrag = .moving
    return
}
// 3. Empty space deselects.
selectedIndex = nil
activeDrag = .none
```

Then in `mouseDragged`:

- **`.moving`** ([line 173](../Sources/screengrabber/CanvasView.swift#L173)):
  computes how far the mouse moved from `moveFrom` and shifts *both* endpoints by
  that delta. It offsets from the *original* endpoints captured on mouse-down
  (`moveOrigStart` / `moveOrigEnd`), not the live values — that avoids drift
  accumulating over a long drag.

- **`.resizing(ref)`** ([line 178](../Sources/screengrabber/CanvasView.swift#L178)):
  delegates to [`applyResize`](#resizing-math) with the specific handle being
  dragged.

## Hit-testing

"Hit-testing" = given a click point, what (if anything) is there? Two functions:

**`handleHit(at:annotation:)`** ([line 366](../Sources/screengrabber/CanvasView.swift#L366))
— is the point within tolerance of any control point of a given shape?

```swift
let tol = handleTolerance
for (ref, pt) in handles(for: a) where abs(pt.x - p.x) <= tol && abs(pt.y - p.y) <= tol {
    return ref
}
return nil
```

`handleTolerance` ([line 112](../Sources/screengrabber/CanvasView.swift#L112)) is
`max(6, 8 / scale)` — expressed in image pixels but kept ~constant *on screen* by
dividing by `scale`, so handles are equally easy to grab whatever the zoom.

**`bodyHit(at:)`** ([line 374](../Sources/screengrabber/CanvasView.swift#L374)) —
which shape's body is under the point? It iterates **`.reversed()`** so the
*topmost* (last drawn) shape wins, matching what you see:

```swift
for i in annotations.indices.reversed() {
    let a = annotations[i]
    switch a.tool {
    case .arrow, .line:
        // an arrow/line has no area, so measure distance to the segment
        if distanceToSegment(p, a.start, a.end) <= max(a.lineWidth, 8 / scale) { return i }
    case .text:
        if textRect(for: a).insetBy(dx: -6/scale, dy: -6/scale).contains(p) { return i }
    default:   // rectangle / ellipse / blur / box — test the bounding rect
        if rect(for: a).insetBy(dx: -6/scale, dy: -6/scale).contains(p) { return i }
    }
}
return nil
```

Two things to note:

- Arrows are **lines** with no interior, so they use
  [`distanceToSegment`](../Sources/screengrabber/CanvasView.swift#L389) (classic
  point-to-line-segment distance) instead of a rectangle containment test.
- The `insetBy(dx: -6/scale, …)` *grows* the rect by ~6px on screen, giving a
  forgiving click target. (`insetBy` with a negative amount expands.)
- Ellipses use their bounding rect for hit-testing, not the true ellipse — clicking
  just outside the curve but inside the box still selects. A deliberate
  simplification.

## Control points (handles)

`handles(for:)` ([line 398](../Sources/screengrabber/CanvasView.swift#L398)) returns
the list of `(HandleRef, point)` pairs for a shape. This single function feeds
*both* drawing the handles and hit-testing them, so they can never disagree.

```swift
private func handles(for a: Annotation) -> [(HandleRef, CGPoint)] {
    switch a.tool {
    case .text:
        return []   // text is move-only — no resize handles
    case .arrow, .line:
        return [(.arrowStart, a.start), (.arrowEnd, a.end)]   // two endpoints
    default:
        // rect-like: 8 handles = 4 corners + 4 edge midpoints (skip the center)
        let r = rect(for: a)
        let xs: [(Axis, CGFloat)] = [(.lo, r.minX), (.mid, r.midX), (.hi, r.maxX)]
        let ys: [(Axis, CGFloat)] = [(.lo, r.minY), (.mid, r.midY), (.hi, r.maxY)]
        var out: [(HandleRef, CGPoint)] = []
        for (ax, xv) in xs {
            for (ay, yv) in ys where !(ax == .mid && ay == .mid) {  // skip center
                out.append((.rect(x: ax, y: ay), CGPoint(x: xv, y: yv)))
            }
        }
        return out
    }
}
```

The handle *identity* is encoded by two small enums ([lines 32–39](../Sources/screengrabber/CanvasView.swift#L32)):

```swift
private enum Axis: Equatable { case lo, mid, hi }   // low edge / middle / high edge

private enum HandleRef: Equatable {
    case arrowStart, arrowEnd
    case rect(x: Axis, y: Axis)   // e.g. .rect(x: .lo, y: .hi) is the top-left corner
}
```

So a rectangle's eight handles are `.rect(x:.lo,y:.lo)`, `.rect(x:.mid,y:.lo)`,
`.rect(x:.hi,y:.lo)`, … — every `(x, y)` combination of low/mid/high *except* the
center `(mid, mid)`. The `where !(ax == .mid && ay == .mid)` clause drops the center.

Handles are **drawn** in `drawSelection` ([line 518](../Sources/screengrabber/CanvasView.swift#L518)):
small white squares with an accent border, plus a dashed bounding box for rect-like
shapes (everything except the two-endpoint arrow and line). Crucially this is done in
**view space** (each handle point run through
`imageToView`) so the squares stay 8×8 pixels regardless of zoom.

## Resizing math

`applyResize(_:ref:to:)` ([line 418](../Sources/screengrabber/CanvasView.swift#L418))
turns "this handle dragged to point `p`" into new `start`/`end` values:

```swift
switch ref {
case .arrowStart: a.start = p          // arrow endpoints: trivial
case .arrowEnd:   a.end = p
case .rect(let ax, let ay):
    let minSize: CGFloat = 4
    var minX = min(a.start.x, a.end.x), maxX = max(a.start.x, a.end.x)
    var minY = min(a.start.y, a.end.y), maxY = max(a.start.y, a.end.y)
    switch ax {
    case .lo:  minX = min(p.x, maxX - minSize)   // dragging the left edge
    case .hi:  maxX = max(p.x, minX + minSize)   // dragging the right edge
    case .mid: break                             // a top/bottom handle: x is fixed
    }
    switch ay {
    case .lo:  minY = min(p.y, maxY - minSize)
    case .hi:  maxY = max(p.y, minY + minSize)
    case .mid: break
    }
    a.start = CGPoint(x: minX, y: minY)
    a.end   = CGPoint(x: maxX, y: maxY)
}
```

The clever part is how the `Axis` decomposition makes corners and edges fall out of
the same code:

- A **corner** handle has a real axis on *both* x and y (e.g. `.rect(x:.lo, y:.hi)`),
  so it moves the left edge *and* the top edge.
- An **edge-midpoint** handle has `.mid` on one axis, whose `case .mid: break`
  leaves that dimension untouched — so a left-edge handle moves only x.

The `minSize`/`min`/`max` clamps stop a rectangle from collapsing or inverting when
you drag one edge past the opposite one.

## Rendering each shape

`rect(for:)` ([line 561](../Sources/screengrabber/CanvasView.swift#L561)) normalizes
the two stored points into a proper rectangle (handles `start`/`end` being in any
order):

```swift
CGRect(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y),
       width: abs(a.end.x - a.start.x), height: abs(a.end.y - a.start.y))
```

`render(_:into:)` ([line 568](../Sources/screengrabber/CanvasView.swift#L568)) is the
heart of drawing — a `switch` over the tool, drawing into the (already
transformed) context in image coordinates:

```swift
switch a.tool {
case .rectangle: ctx.setStrokeColor(a.color.cgColor); ctx.setLineWidth(a.lineWidth)
                 ctx.stroke(rect(for: a))
case .ellipse:   ctx.setStrokeColor(a.color.cgColor); ctx.setLineWidth(a.lineWidth)
                 ctx.strokeEllipse(in: rect(for: a))
case .arrow:     drawArrow(from: a.start, to: a.end, color: a.color, width: a.lineWidth, into: ctx)
case .line:      ctx.setStrokeColor(a.color.cgColor); ctx.setLineWidth(a.lineWidth)   // arrow, no head
                 ctx.setLineCap(.round); ctx.move(to: a.start); ctx.addLine(to: a.end); ctx.strokePath()
case .box:       ctx.setFillColor(NSColor.black.cgColor); ctx.fill(rect(for: a))   // redaction
case .blur:      pixelate(rect(for: a), into: ctx)
case .text:      drawText(a, into: ctx)
}
```

The arrow ([`drawArrow`, line 604](../Sources/screengrabber/CanvasView.swift#L604))
is the most involved primitive: it computes the angle from tail to tip with
`atan2`, draws the shaft *stopping short of the tip* (so the line doesn't poke
through the head), then builds a filled triangle for the head from two points offset
±0.45 rad from the reverse direction. Worth reading if you want to add a similar
directional shape.

`render` is wrapped in `ctx.saveGState()` / `ctx.restoreGState()` so each shape's
stroke color, line width, etc. can't leak into the next one.

## Text: a special case

Text is the one tool that doesn't fit the two-point mold, so it has the most
supporting code. Key pieces (all in the `// MARK: - Text metrics` and rendering
sections):

- **Storage:** `start` is the top-left anchor; the string lives in `a.text`, the
  size in `a.fontSize`. `end` is ignored.

- **Multi-line:** `textLines(of:)` ([line 453](../Sources/screengrabber/CanvasView.swift#L453))
  splits on `\n`. Layout uses CoreText (`CTLine`) for accurate per-line widths.

- **Metrics:** `textMetrics(_:)` ([line 472](../Sources/screengrabber/CanvasView.swift#L472))
  computes ascent/descent/line-height from the font and the widest line. From that,
  `textRect(for:)` ([line 483](../Sources/screengrabber/CanvasView.swift#L483))
  derives the bounding box (used for selection and hit-testing). Because CG's origin
  is bottom-left, the box extends *downward* from `start`: `y: a.start.y - height`.

- **Drawing:** `drawText` ([line 592](../Sources/screengrabber/CanvasView.swift#L592))
  positions each line's baseline and draws it with `CTLineDraw`.

- **The caret:** while you're typing, `drawCaret` ([line 545](../Sources/screengrabber/CanvasView.swift#L545))
  draws a blinking-style vertical bar at the end of the last line.

- **Entering/leaving editing:** clicking with the text tool creates an empty box and
  sets `editingTextIndex`; double-clicking an existing text box in Select mode
  re-enters editing ([line 143](../Sources/screengrabber/CanvasView.swift#L143));
  `commitTextEditing` ([line 310](../Sources/screengrabber/CanvasView.swift#L310))
  ends editing and **discards a box you never typed into** so stray clicks don't
  litter empty text.

Text keystrokes are handled in `keyDown` — see [keyboard handling](#keyboard-handling).

## The blur tool

`pixelate(_:into:)` ([line 631](../Sources/screengrabber/CanvasView.swift#L631))
obscures a region by mosaicing it — useful for hiding tokens, emails, or faces:

1. **Crop** the source region out of the original `image`. Note the y-flip: `CGImage`
   crops with a **top-left** origin, but our rect is bottom-left, so it computes
   `y: imageSize.height - intRect.maxY`.
2. **Downscale** the crop into a tiny off-screen context (~16 blocks on the long
   side) with smooth interpolation — this averages each block to one color.
3. **Upscale** that tiny image back to the region with `interpolationQuality = .none`
   (nearest-neighbor), so each block stays a flat, hard-edged square.

It samples the *original* image, not the canvas, so blur regions never sample each
other's output and stay stable as you move them.

## Keyboard handling

`keyDown(with:)` ([line 227](../Sources/screengrabber/CanvasView.swift#L227)) has two
modes:

**While editing text** (`editingTextIndex != nil`): keystrokes mutate `a.text`.

- `Return`/`Enter` → newline (but **⌘Return commits** and exits).
- `Esc` → commit and return to Select mode.
- `Backspace` → delete last character.
- Any other key → append its characters, after stripping control chars (arrow keys,
  etc.) so they don't insert garbage.

**Otherwise:**

- `handleToolShortcut` ([line 282](../Sources/screengrabber/CanvasView.swift#L282))
  maps plain keys to tools: `1` Select, then `2`… follow `Tool.paletteOrder`
  (`2` Arrow, `3` Line, `4` Rectangle, `5` Circle, `6` Blur, `7` Box), plus `T` Text.
  It bails if any modifier is held so it can't clash with shortcuts.
- `Delete`/`Backspace` (keyCodes 51/117) with a selection → remove the selected
  shape.

`performKeyEquivalent` ([line 264](../Sources/screengrabber/CanvasView.swift#L264))
separately handles ⌘-shortcuts that an accessory app's (absent) menu bar would
normally provide: **⌘,** opens Preferences, **⌘W** closes the window.

> macOS key codes are hardware virtual key codes, not characters — `36` is Return,
> `53` is Escape, `51` is Backspace, etc. That's why you see raw numbers in the
> `switch`.

## Export / flattening

`compositeImage()` ([line 665](../Sources/screengrabber/CanvasView.swift#L665))
produces the final, full-resolution annotated image:

```swift
commitTextEditing()                    // finalize any open text edit first
let w = image.width, h = image.height  // full pixel dimensions
// make an off-screen sRGB bitmap context at full resolution
let ctx = CGContext(data: nil, width: w, height: h, …)
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // the screenshot
for a in annotations { render(a, into: ctx) }                 // the same render!
return ctx.makeImage()
```

The important detail: **no coordinate transform here.** The bitmap is already at full
pixel size, annotations are stored in pixel coordinates, so `render` draws them 1:1.
That's the whole reason annotations are stored in image space — export is "draw the
image, then replay the exact same `render` calls you used on screen."

Callers ([`EditorWindowController`](../Sources/screengrabber/EditorWindowController.swift))
take that `CGImage` and either write a PNG (Save…), put it on the clipboard (Copy),
or overwrite the auto-saved file on window close.

## The redraw cycle

`CanvasView` never draws "directly." Instead, any code that changes state sets
`needsDisplay = true`, which asks AppKit to call `draw(_:)` on the next frame. You'll
see `needsDisplay = true` at the end of nearly every mutating method. `draw(_:)`
([line 491](../Sources/screengrabber/CanvasView.swift#L491)) then redraws
*everything* from the current data, in this order:

1. Dark background fill (the letterbox bars around the image).
2. The screenshot (`ctx.draw(image, in: imageRect)`).
3. All committed annotations + the draft, under the image-space transform.
4. The text caret, if editing.
5. Selection chrome (dashed box + handles), in view space.

Because the whole frame is rebuilt from `annotations` each time, **the data is the
single source of truth** — there's no separate visual state that can fall out of
sync. Keep that invariant when you add features: change the data, set
`needsDisplay`, let `draw` sort it out.

---

**Next:** ready to extend it? → [Adding shapes & extending editing](adding-shapes.md).
