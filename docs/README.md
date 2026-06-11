# ScreenGrabber Developer Docs

These docs explain how ScreenGrabber works **under the hood** — written for someone
new to the codebase (and not necessarily fluent in Swift). If you want to add a
feature, fix a bug, or just understand the design, start here.

For *using* the app (install, hotkeys, settings), see the top-level
[README](../README.md) instead.

## Contents

1. **[Architecture overview](architecture.md)** — the big picture: how a screenshot
   travels from a hotkey press to a saved PNG, and what each source file is
   responsible for. Read this first.

2. **[The Canvas editor, in depth](canvas-editor.md)** — a deep dive on
   `CanvasView`, the heart of the app. Covers the annotation data model, the two
   coordinate systems, drawing vs. selecting, hit-testing, control-point resizing,
   text editing, and export. This is where most of the interesting logic lives.

3. **[Adding shapes & extending editing](adding-shapes.md)** — a practical,
   step-by-step guide. Walks through adding a brand-new shape end to end, then
   covers richer editing features (rotation, fill, a real undo/redo stack).

## A note on Swift for newcomers

A few Swift-isms that show up everywhere in this codebase:

- **`struct` vs `class`** — `struct` is a *value type* (copied when assigned, like a
  number); `class` is a *reference type* (shared, like an object pointer). An
  `Annotation` is a `struct` — copying it copies the whole shape. A `CanvasView` is
  a `class` — there's one of it and everyone points at the same instance.
- **`enum`** — a fixed set of named cases (`Tool.arrow`, `Tool.rectangle`, …). Swift
  enums can also carry associated data (`HandleRef.rect(x:y:)` carries two axes).
- **`var` / `let`** — `var` is mutable, `let` is a constant.
- **`?` (optionals)** — `Int?` means "an `Int` or nothing (`nil`)." `selectedIndex`
  is `Int?` because sometimes nothing is selected. `if let i = selectedIndex { … }`
  unwraps it safely.
- **`inout`** — a parameter passed by reference so the function can mutate the
  caller's copy (e.g. `applyResize(_ a: inout Annotation, …)`).
- **`@objc` / `#selector`** — glue for AppKit's older target/action callback system
  (buttons, sliders). The `@objc` marks a method callable from that system;
  `#selector(foo(_:))` names it.
- **closures `{ [weak self] in … }`** — inline functions stored as callbacks. `[weak
  self]` avoids a retain cycle (a memory leak) by not keeping `self` alive.

You don't need to master these to follow the docs — they're cross-referenced as
they come up.
