# Adding shapes & extending editing

This is the hands-on guide. It assumes you've skimmed
[The Canvas editor, in depth](canvas-editor.md) — at minimum the
[data model](canvas-editor.md#the-annotation-data-model) and
[immediate-mode](canvas-editor.md#why-immediate-mode) sections.

Two parts:

- [**Part 1 — Add a new shape**](#part-1--add-a-new-shape), end to end, with a
  complete worked example (a straight **line** tool).
- [**Part 2 — Richer editing**](#part-2--richer-editing): rotation, fill colors, and
  a real undo/redo stack.

---

## The mental model

Because shapes are just `Annotation` data drawn by a `switch`, adding one is mostly
"add a `case` in the same handful of places." There's a natural checklist. For any
**two-point shape** (defined by a `start` and an `end`, like every existing shape
except text), you touch:

| # | Where | What you add |
|---|-------|--------------|
| 1 | `Tool` enum | a new `case` (appended) |
| 2 | `Tool` extension | a slot in `paletteOrder` (UI position) + `symbolName` / `displayName` / `persistID` |
| 3 | `render(_:into:)` | how to draw it |
| 4 | `bodyHit(at:)` | how clicking selects it |
| 5 | `handles(for:)` | its resize handles (often reuse arrow/rect logic) |
| 6 | `applyResize` | how dragging a handle reshapes it (often already covered) |
| 7 | `drawSelection` | (only if it shouldn't get the default dashed box) |

The **toolbar button and number-key shortcut come for free** from step 2: both the
segmented control and `handleToolShortcut` are generated from `Tool.paletteOrder`, so
adding your tool to that array is all the UI wiring you need (only a *letter* shortcut,
like Text's `T`, takes an extra line). Steps 5–7 are frequently free too: if your shape
resizes like an arrow/line (two endpoints) or a rectangle (eight handles), the existing
handle/resize/selection code already covers it once you slot the tool into the right
branch.

---

## Part 1 — Add a new shape

The **Line** tool — a straight line (an arrow without the head) — is already built in,
and it's the reference for this guide: it resizes just like an arrow (two endpoint
handles), so it leans entirely on the arrow's machinery. Read along, and when you build
your *own* shape, substitute your case name (`.highlighter`, `.star`, …) for `.line`.

All edits are in [`CanvasView.swift`](../Sources/screengrabber/CanvasView.swift)
unless noted.

### Step 1 — Add the enum case (appended)

```swift
enum Tool: Int {
    case arrow = 0
    case rectangle
    case ellipse
    case blur
    case box
    case text
    case line        // ← appended, rawValue 6
}
```

> ⚠️ **Append, never reorder.** `rawValue` is *storage only* (e.g. the persisted
> "default tool" looks tools up by `persistID`, not number). Appending keeps every
> existing value stable. Where the tool *appears* in the UI is decided separately, in
> step 2 — so you never have to renumber anything to position a tool.

### Step 2 — Slot it into the palette + add metadata

The toolbar order, number-key shortcuts, and the settings popup all read
[`Tool.paletteOrder`](../Sources/screengrabber/CanvasView.swift). Put your tool wherever
you want it to appear (Line sits right after Arrow), and add its display metadata to the
`Tool` extension:

```swift
static let paletteOrder: [Tool] = [.arrow, .line, .rectangle, .ellipse, .blur, .box, .text]

var symbolName: String { switch self { … case .line: return "line.diagonal" … } }
var displayName: String { switch self { … case .line: return "Line" … } }
var persistID:  String { switch self { … case .line: return "line" … } }   // stable id for storage
```

That's the *entire* UI wiring: the segmented control (step 7) and the `2`…`7` shortcuts
build themselves from this array, and "Line" shows up in the Settings ▸ Default tool
popup automatically. `symbolName` is an [SF Symbol](https://developer.apple.com/sf-symbols/)
(`line.diagonal` ships with macOS).

### Step 2 — Draw it

Add a case to `render(_:into:)`
([~line 568](../Sources/screengrabber/CanvasView.swift#L568)):

```swift
case .line:
    ctx.setStrokeColor(a.color.cgColor)
    ctx.setLineWidth(a.lineWidth)
    ctx.setLineCap(.round)
    ctx.move(to: a.start)
    ctx.addLine(to: a.end)
    ctx.strokePath()
```

Remember you're drawing in **image-pixel coordinates** — the context transform set up
in `draw(_:)` takes care of scaling to the screen, and `compositeImage()` reuses the
same code at full resolution. You don't think about either; just draw the geometry.

### Step 3 — Make it clickable (`bodyHit`)

A line has no interior, so it's hit-tested like an arrow — by distance to the
segment. Add `.line` alongside `.arrow` in `bodyHit(at:)`
([~line 374](../Sources/screengrabber/CanvasView.swift#L374)):

```swift
switch a.tool {
case .arrow, .line:                                   // ← add .line
    if distanceToSegment(p, a.start, a.end) <= max(a.lineWidth, 8 / scale) { return i }
case .text:
    if textRect(for: a).insetBy(dx: -6/scale, dy: -6/scale).contains(p) { return i }
default:
    if rect(for: a).insetBy(dx: -6/scale, dy: -6/scale).contains(p) { return i }
}
```

### Step 4 — Give it handles (`handles(for:)`)

A line's control points are its two endpoints — identical to an arrow. Add `.line`
to the arrow branch ([~line 398](../Sources/screengrabber/CanvasView.swift#L398)):

```swift
switch a.tool {
case .text:
    return []
case .arrow, .line:                                   // ← add .line
    return [(.arrowStart, a.start), (.arrowEnd, a.end)]
default:
    … // 8 rect handles
}
```

### Step 5 — Resizing (`applyResize`) — already done

Because the handles we returned are `.arrowStart` / `.arrowEnd`, `applyResize`
([~line 418](../Sources/screengrabber/CanvasView.swift#L418)) already knows what to
do (`a.start = p` / `a.end = p`). **No change needed.** This is the payoff of
reusing the arrow's handle identities.

### Step 6 — Selection chrome (`drawSelection`)

`drawSelection` ([~line 518](../Sources/screengrabber/CanvasView.swift#L518)) draws a
dashed bounding box for everything *except* arrows. A line should also skip the box
(it'd just show two endpoint handles). Change the guard:

```swift
if a.tool != .arrow && a.tool != .line {              // ← exclude .line too
    let r = (a.tool == .text) ? textRect(for: a) : rect(for: a)
    … // dashed bounding box
}
```

The handle-drawing loop below it needs no change — it already iterates whatever
`handles(for:)` returns.

### Step 7 — Toolbar button & shortcut — already done

Nothing to write here. `makeToolControl()`
([~line 121](../Sources/screengrabber/EditorWindowController.swift#L121)) builds one
segment per entry in `Tool.paletteOrder` (after the Select segment), pulling each
tool's `symbolName` and `displayName`, and `handleToolShortcut`
([~line 282](../Sources/screengrabber/CanvasView.swift#L282)) maps `"1"` to Select and
`"2"`… to `paletteOrder` positions. Because you added `.line` to `paletteOrder` in
step 2, it already has a button (with the `line.diagonal` icon, tooltip "Line (3)") and
the `3` shortcut.

> A tool keyed by a *letter* rather than a number — like Text's `T` — is the one case
> that needs an explicit line in `handleToolShortcut` (`if ch == "t" { pickTool(.text) }`).

### Step 8 — Build & test

```bash
./build.sh && open dist/ScreenGrabber.app
```

Capture a region, hit the Line button (or press `3`), drag a line. Switch to
Select, click it, drag an endpoint to reshape it, drag the middle to move it, change
the color while it's selected, press Delete. All of that works from the steps above —
no extra wiring, because each subsystem learned about `.line` in exactly one place.

### What if the shape needs more than two points?

The whole `start`/`end` model assumes two points. Some shapes don't fit:

- **A shape with a thickness/parameter** (e.g. a rounded-rect with a corner radius, a
  star with N points): add a field to `Annotation`
  ([line 16](../Sources/screengrabber/CanvasView.swift#L16)), e.g.
  `var cornerRadius: CGFloat = 0`, give it a default so existing code compiles, and
  read it in `render`.
- **A polyline / freehand / polygon** (arbitrary point count): add
  `var points: [CGPoint] = []`. Now `bodyHit`, `handles`, and `applyResize` need
  real per-point logic instead of reusing the two-point branches — this is the one
  case that touches more than a `case`. Budget for it.

Either way, the *structure* is the same: data on `Annotation`, behavior in the same
small set of functions.

---

## Part 2 — Richer editing

The shapes are already movable, resizable, recolorable, and re-widthable. Here are
the natural next features and where they slot in.

### Rotation

Goal: a handle above the shape that spins it.

1. **Data:** add `var rotation: CGFloat = 0` (radians) to `Annotation`.
2. **Render:** in `render`, rotate the context around the shape's center before
   drawing:
   ```swift
   let c = CGPoint(x: rect(for: a).midX, y: rect(for: a).midY)
   ctx.translateBy(x: c.x, y: c.y)
   ctx.rotate(by: a.rotation)
   ctx.translateBy(x: -c.x, y: -c.y)
   ```
   (Inside the existing `saveGState`/`restoreGState`, so it resets per shape.)
3. **Handle:** add a `.rotation` case to `HandleRef` and return a point offset above
   the shape from `handles(for:)`.
4. **Drag:** add a `.rotating` case to the `Drag` enum and, in `mouseDragged`,
   compute `atan2` from the shape's center to the mouse to set `a.rotation`.
5. **Hit-testing gotcha:** `bodyHit` tests the *unrotated* rect. For correctness
   you'd rotate the click point by `-rotation` around the center before the
   containment test. (Often skippable for a first pass.)

### Fill color for rectangles & ellipses

1. **Data:** `var fillColor: NSColor? = nil` (`nil` = no fill, today's behavior).
2. **Render:** before the stroke in the `.rectangle` / `.ellipse` cases:
   ```swift
   if let fill = a.fillColor {
       ctx.setFillColor(fill.cgColor)
       ctx.fill(rect(for: a))   // or ctx.fillEllipse(in:)
   }
   ```
3. **UI:** add a second color well (or a fill/stroke toggle) in
   `EditorWindowController`, calling a new `canvas.setSelectedFillColor(_:)` modeled
   on `setSelectedColor`
   ([line 340](../Sources/screengrabber/CanvasView.swift#L340)).

### A real undo/redo stack

Today's `undo()` ([line 324](../Sources/screengrabber/CanvasView.swift#L324)) just
`removeLast()` — it can't undo a *move*, *resize*, *recolor*, or *delete*, only the
last drawn shape. A proper history:

1. **Snapshot before each mutation.** Because `Annotation` is a value type, a whole
   snapshot is just `annotations` (the array copies cheaply):
   ```swift
   private var undoStack: [[Annotation]] = []
   private var redoStack: [[Annotation]] = []

   private func pushUndo() {
       undoStack.append(annotations)
       redoStack.removeAll()
   }
   ```
2. **Call `pushUndo()`** at the *start* of each user edit: before appending a drawn
   shape (`mouseUp`), before a move/resize drag (`beginSelection`), before delete,
   before color/width/font changes, before `clearAll`.
3. **Undo / redo:**
   ```swift
   func undo() {
       guard let prev = undoStack.popLast() else { return }
       redoStack.append(annotations)
       annotations = prev
       selectedIndex = nil
       needsDisplay = true
   }
   ```
   …and a mirror-image `redo()`. Wire `redo` to ⇧⌘Z in
   [`EditorWindowController`](../Sources/screengrabber/EditorWindowController.swift).

> AppKit also offers a built-in `UndoManager`; the manual stack above is shown
> because it's explicit and matches the codebase's plain-data style. Either is fine.

---

## Testing your change

There's no unit-test target — this is a UI app, so test by running it:

```bash
./build.sh                 # compile + assemble + ad-hoc sign → dist/ScreenGrabber.app
open dist/ScreenGrabber.app
```

Then capture (⇧⌘4 or the menu-bar icon) and exercise the new shape:

- Draw it; confirm it auto-switches to Select mode and is selected.
- Move it (drag the body), resize it (drag a handle).
- Restyle it (color well / width slider while selected).
- Delete it (Delete/Backspace), Undo it, Clear all.
- **Export check:** Save… (or Copy) and confirm the shape renders crisply at full
  resolution — this verifies your `render` case works under both the on-screen
  transform and the export path.

The ad-hoc signing in `build.sh` keeps the Screen Recording permission across
rebuilds, so you won't have to re-grant it each time.

---

**See also:** [The Canvas editor, in depth](canvas-editor.md) ·
[Architecture overview](architecture.md)
