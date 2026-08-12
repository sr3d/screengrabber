import AppKit
import CoreText

enum Tool: Int {
    case arrow = 0
    case rectangle
    case ellipse
    case blur
    case box
    case text
    case line        // appended (rawValue 6); display order lives in `paletteOrder`
}

extension Tool {
    /// The order tools appear in the toolbar and under the number-key shortcuts
    /// (segment 0 / key "1" is Select, handled separately). This is decoupled
    /// from `rawValue` so tools can be reordered without breaking storage.
    static let paletteOrder: [Tool] = [.arrow, .line, .rectangle, .ellipse, .blur, .box, .text]

    /// SF Symbol name for the toolbar.
    var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .blur: return "square.grid.3x3.fill"
        case .box: return "rectangle.fill"
        case .text: return "character"
        }
    }

    /// Human-readable name for tooltips and the settings popup.
    var displayName: String {
        switch self {
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Circle"
        case .blur: return "Blur"
        case .box: return "Box"
        case .text: return "Text"
        }
    }

    /// A stable string id for persistence (never store `rawValue`, which can shift).
    var persistID: String {
        switch self {
        case .arrow: return "arrow"
        case .line: return "line"
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .blur: return "blur"
        case .box: return "box"
        case .text: return "text"
        }
    }

    init?(persistID: String) {
        guard let match = ([.arrow, .line, .rectangle, .ellipse, .blur, .box, .text] as [Tool])
            .first(where: { $0.persistID == persistID }) else { return nil }
        self = match
    }
}

/// One drawn annotation, stored in image-pixel coordinates with a bottom-left
/// origin (matching Core Graphics' default), so the same `render` path serves
/// both on-screen display and full-resolution export.
struct Annotation {
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""        // used by the .text tool only
    var fontSize: CGFloat = 28   // used by the .text tool only
}

/// The drawing surface. It letterboxes the captured image to fit, maps mouse
/// input into image-pixel space, composites annotations over the image, and —
/// in Select mode — lets you move and resize existing shapes via control points.
final class CanvasView: NSView {

    // Which edge along an axis a rect handle controls.
    private enum Axis: Equatable { case lo, mid, hi }

    // Identifies a control point. Arrows have two endpoints; rect-like shapes
    // have up to eight edge/corner handles.
    private enum HandleRef: Equatable {
        case arrowStart, arrowEnd
        case rect(x: Axis, y: Axis)
    }

    private enum Drag {
        case none, drawing, moving, resizing(HandleRef)
    }

    private var image: CGImage
    private var imageSize: CGSize

    private(set) var annotations: [Annotation] = []
    private var draft: Annotation?

    /// Undo history: the whole canvas state (base image + annotations) snapshotted
    /// before each discrete edit, so Cmd-Z reverts draws, deletes, clears, and
    /// crops alike — in the order they happened.
    private struct Snapshot {
        let image: CGImage
        let imageSize: CGSize
        let annotations: [Annotation]
    }
    private var undoStack: [Snapshot] = []
    /// Tracks the snapshot pushed when a *new* text box is placed, so it can be
    /// dropped if the box is abandoned empty (avoids a dead undo step).
    private var newTextUndoPushed = false

    // Crop mode: drag a rectangle, Return to apply, Esc to cancel.
    private(set) var cropMode = false
    private var cropDraft: CGRect?        // selection in image px (bottom-left origin)
    private var cropAnchor: CGPoint = .zero
    private var cropDragging = false

    var currentTool: Tool = .arrow
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 4
    var currentFontSize: CGFloat = 28

    /// When true, clicks select / move / resize existing shapes instead of
    /// drawing new ones.
    var selectMode = false {
        didSet {
            needsDisplay = true
            updateLiveText()
        }
    }
    private(set) var selectedIndex: Int?
    private var editingTextIndex: Int?

    // Live Text: select text straight off the image, like Preview. Automatic in
    // Select mode; `textSelectMode` is the explicit toolbar toggle, which claims
    // the whole image instead of only the recognized-text regions.
    private(set) var textSelectMode = false
    private let liveText = LiveTextOverlay()

    /// Bumped on every discrete edit, so the Live Text analysis knows when the
    /// image it was made from is stale.
    private var editGeneration = 0

    /// Called after a drag-drawn shape is committed, so the host can flip the
    /// toolbar into Select mode (the new shape is already selected).
    var onDrawFinished: (() -> Void)?

    /// Called when a keyboard shortcut picks a tool, with the toolbar segment
    /// index to highlight (0 = Select, then the tool's position in
    /// `Tool.paletteOrder` + 1).
    var onToolPicked: ((Int) -> Void)?

    /// Called when ⌘, is pressed, to open Preferences.
    var onOpenPreferences: (() -> Void)?

    /// Called when ⌘O is pressed, to open another image in a new editor.
    var onOpenImage: (() -> Void)?

    /// Called when the base image's pixel size changes (a crop, or undoing one),
    /// so the host window can resize to the new aspect ratio.
    var onImageSizeChanged: ((CGSize) -> Void)?

    /// Called when text-select mode turns itself off (Esc, or a tool change), so
    /// the host can un-highlight the toolbar toggle.
    var onTextSelectModeChanged: ((Bool) -> Void)?

    private var activeDrag: Drag = .none
    private var moveFrom: CGPoint = .zero
    private var moveOrigStart: CGPoint = .zero
    private var moveOrigEnd: CGPoint = .zero

    init(image: CGImage) {
        self.image = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
        wantsLayer = true

        liveText.hasAnnotation = { [weak self] point in
            guard let self = self else { return false }
            return self.hasAnnotation(atViewPoint: point)
        }
        liveText.onEscape = { [weak self] in self?.exitTextSelectMode() }
        addSubview(liveText)
    }

    /// Keeps the Live Text overlay exactly over the drawn image, so its selection
    /// highlights line up and its contents rect is the full unit square.
    override func layout() {
        super.layout()
        liveText.frame = imageRect
        liveText.updateContentsRect()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Coordinate mapping

    /// The rect (in view points) where the image is drawn, aspect-fit & centered.
    private var imageRect: CGRect {
        let bw = bounds.width, bh = bounds.height
        guard imageSize.width > 0, imageSize.height > 0, bw > 0, bh > 0 else { return .zero }
        let s = min(bw / imageSize.width, bh / imageSize.height)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return CGRect(x: (bw - w) / 2, y: (bh - h) / 2, width: w, height: h)
    }

    /// Image-pixels per view-point.
    private var scale: CGFloat {
        let r = imageRect
        return imageSize.width > 0 ? r.width / imageSize.width : 1
    }

    /// Hit-test slop, expressed in image pixels but constant on screen.
    private var handleTolerance: CGFloat { max(6, 8 / scale) }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return .zero }
        let x = (v.x - r.minX) * imageSize.width / r.width
        let y = (v.y - r.minY) * imageSize.height / r.height
        return CGPoint(x: clamp(x, 0, imageSize.width), y: clamp(y, 0, imageSize.height))
    }

    private func imageToView(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + p.x * scale, y: r.minY + p.y * scale)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(from: event)

        // Any click finalizes an in-progress text edit first.
        commitTextEditing()

        // In text-select mode the overlay claims the image; anything that reaches
        // us is a click on the letterbox margin, which should do nothing.
        if textSelectMode { return }

        if cropMode {
            cropAnchor = p
            cropDraft = CGRect(origin: p, size: .zero)
            cropDragging = true
            needsDisplay = true
            return
        }

        if selectMode {
            // Double-click a text box re-enters editing.
            if event.clickCount == 2, let i = bodyHit(at: p), annotations[i].tool == .text {
                selectedIndex = i
                editingTextIndex = i
                needsDisplay = true
                return
            }
            beginSelection(at: p)
        } else if currentTool == .text {
            // Place a text box at the click point and start typing.
            pushUndo()
            newTextUndoPushed = true
            var a = Annotation(tool: .text, start: p, end: p,
                               color: currentColor, lineWidth: currentLineWidth)
            a.fontSize = currentFontSize
            annotations.append(a)
            let idx = annotations.count - 1
            selectedIndex = idx
            editingTextIndex = idx
            activeDrag = .none
        } else {
            draft = Annotation(tool: currentTool, start: p, end: p,
                               color: currentColor, lineWidth: currentLineWidth)
            activeDrag = .drawing
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if textSelectMode { return }
        let p = imagePoint(from: event)
        if cropMode {
            if cropDragging { cropDraft = rectBetween(cropAnchor, p); needsDisplay = true }
            return
        }
        switch activeDrag {
        case .drawing:
            draft?.end = p
        case .moving:
            guard let i = selectedIndex else { break }
            let dx = p.x - moveFrom.x, dy = p.y - moveFrom.y
            annotations[i].start = CGPoint(x: moveOrigStart.x + dx, y: moveOrigStart.y + dy)
            annotations[i].end = CGPoint(x: moveOrigEnd.x + dx, y: moveOrigEnd.y + dy)
        case .resizing(let ref):
            guard let i = selectedIndex else { break }
            applyResize(&annotations[i], ref: ref, to: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if textSelectMode { return }
        if cropMode {
            cropDragging = false
            needsDisplay = true   // keep cropDraft on screen until Return / Esc
            return
        }
        var didDraw = false
        if case .drawing = activeDrag, var d = draft {
            d.end = imagePoint(from: event)
            if hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 2 {
                pushUndo()
                annotations.append(d)
                selectedIndex = annotations.count - 1
                didDraw = true
            }
        }
        draft = nil
        activeDrag = .none
        needsDisplay = true
        // Drop straight into Select mode so the fresh shape can be adjusted.
        if didDraw { onDrawFinished?() }
    }

    private func beginSelection(at p: CGPoint) {
        // 1. A handle of the already-selected shape wins (even over other shapes).
        if let i = selectedIndex, i < annotations.count,
           let ref = handleHit(at: p, annotation: annotations[i]) {
            activeDrag = .resizing(ref)
            return
        }
        // 2. Otherwise select the topmost shape under the cursor and move it.
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
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if textSelectMode {
            if event.keyCode == 53 {          // escape leaves the mode
                exitTextSelectMode()
            } else if handleToolShortcut(event) {
                // A tool shortcut switches away; pickTool tears the mode down.
            }
            return
        }

        if cropMode {
            switch event.keyCode {
            case 36, 76: commitCrop()       // return / enter
            case 53:     cancelCrop()        // escape
            default:
                // A tool/Select shortcut leaves crop mode and switches tool.
                if handleToolShortcut(event) { exitCropMode() }
            }
            return
        }

        if let i = editingTextIndex, i < annotations.count {
            switch event.keyCode {
            case 36, 76:       // return / enter -> newline (⌘Return commits)
                if event.modifierFlags.contains(.command) {
                    commitTextEditing()
                } else {
                    annotations[i].text.append("\n")
                }
            case 53:           // escape -> commit and return to Select mode
                commitTextEditing()
                enterSelectMode()
            case 51:           // backspace
                if !annotations[i].text.isEmpty { annotations[i].text.removeLast() }
            default:
                if let chars = event.characters {
                    // Strip control characters (arrows, etc.); keep typed text.
                    let clean = String(chars.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
                    if !clean.isEmpty { annotations[i].text.append(clean) }
                }
            }
            needsDisplay = true
            return
        }

        if handleToolShortcut(event) { return }

        // 51 = delete/backspace, 117 = forward delete.
        if (event.keyCode == 51 || event.keyCode == 117), let i = selectedIndex {
            pushUndo()
            annotations.remove(at: i)
            selectedIndex = nil
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case ",":
                onOpenPreferences?()
                return true
            case "o":
                // The status-bar menu shows ⌘O, but its key equivalents only fire
                // while that menu is open — so wire it here too.
                onOpenImage?()
                return true
            case "w":
                // Accessory apps have no menu bar, so ⌘W isn't wired by default.
                window?.performClose(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Plain-key tool shortcuts: "1" Select; "2"… follow `Tool.paletteOrder`
    /// (2 Arrow, 3 Line, 4 Rectangle, 5 Circle, 6 Blur, 7 Box); "T" Text.
    private func handleToolShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if ch == "1" { enterSelectMode(); return true }
        if ch == "t" { pickTool(.text); return true }
        if let d = Int(ch), d >= 2, d - 2 < Tool.paletteOrder.count {
            pickTool(Tool.paletteOrder[d - 2])
            return true
        }
        return false
    }

    private func pickTool(_ tool: Tool) {
        exitTransientModes()
        selectMode = false
        currentTool = tool
        onToolPicked?(segment(for: tool))
        updateLiveText()
        needsDisplay = true
    }

    /// Toolbar segment index for a tool (segment 0 is Select).
    private func segment(for tool: Tool) -> Int {
        (Tool.paletteOrder.firstIndex(of: tool) ?? 0) + 1
    }

    private func enterSelectMode() {
        exitTransientModes()
        selectMode = true
        onToolPicked?(0)  // highlight the Select segment
        updateLiveText()
        needsDisplay = true
    }

    private func commitTextEditing() {
        guard let i = editingTextIndex else { return }
        editingTextIndex = nil
        // Drop an empty text box that was never typed into — along with the
        // undo snapshot we pushed when it was placed, so Cmd-Z isn't a no-op.
        if i < annotations.count && annotations[i].text.isEmpty {
            annotations.remove(at: i)
            if newTextUndoPushed, !undoStack.isEmpty { undoStack.removeLast() }
            if selectedIndex == i { selectedIndex = nil }
            else if let s = selectedIndex, s > i { selectedIndex = s - 1 }
        }
        newTextUndoPushed = false
        needsDisplay = true
    }

    // MARK: - Editing actions

    /// Captures the current state so the next edit can be undone.
    private func pushUndo() {
        undoStack.append(Snapshot(image: image, imageSize: imageSize, annotations: annotations))
        // Every discrete edit funnels through here, which makes it the one place
        // that has to tell Live Text its analysis is out of date.
        editGeneration += 1
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        editingTextIndex = nil
        newTextUndoPushed = false
        let sizeChanged = snap.imageSize != imageSize
        image = snap.image
        imageSize = snap.imageSize
        annotations = snap.annotations
        selectedIndex = nil
        editGeneration += 1
        if sizeChanged { onImageSizeChanged?(imageSize) }
        updateLiveText()
        needsDisplay = true
    }

    func clearAll() {
        guard !annotations.isEmpty else { return }
        pushUndo()
        editingTextIndex = nil
        annotations.removeAll()
        selectedIndex = nil
        needsDisplay = true
    }

    /// Retarget the selected shape's color (toolbar doubles as a property editor).
    func setSelectedColor(_ color: NSColor) {
        guard let i = selectedIndex else { return }
        annotations[i].color = color
        needsDisplay = true
    }

    func setSelectedLineWidth(_ width: CGFloat) {
        guard let i = selectedIndex else { return }
        annotations[i].lineWidth = width
        needsDisplay = true
    }

    func setSelectedFontSize(_ size: CGFloat) {
        guard let i = selectedIndex, annotations[i].tool == .text else { return }
        annotations[i].fontSize = size
        needsDisplay = true
    }

    /// Font size of the selected text box, if one is selected.
    var selectedTextFontSize: CGFloat? {
        guard let i = selectedIndex, annotations[i].tool == .text else { return nil }
        return annotations[i].fontSize
    }

    // MARK: - Live Text

    /// Turns the overlay on or off to match the current mode, and kicks off an
    /// analysis if the image has changed since the last one.
    ///
    /// The analysis runs on the *composite*, not the base image — so it follows a
    /// crop and, deliberately, cannot select text the user blurred or boxed out.
    private func updateLiveText() {
        guard LiveTextOverlay.isSupported else { return }

        if cropMode || editingTextIndex != nil {
            liveText.activation = .off
        } else if textSelectMode {
            liveText.activation = .forced
        } else if selectMode {
            liveText.activation = .automatic
        } else {
            liveText.activation = .off
        }

        guard liveText.activation != .off else { return }
        liveText.analyze(generation: editGeneration) { [weak self] in self?.compositeImage() }
    }

    func enterTextSelectMode() {
        guard LiveTextOverlay.isSupported else { return }
        commitTextEditing()
        exitCropMode()
        textSelectMode = true
        selectMode = false      // its didSet calls updateLiveText()
        selectedIndex = nil
        updateLiveText()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onTextSelectModeChanged?(true)
    }

    func exitTextSelectMode() {
        guard textSelectMode else { return }
        textSelectMode = false
        liveText.clearSelection()
        enterSelectMode()       // routes through updateLiveText()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onTextSelectModeChanged?(false)
    }

    func toggleTextSelectMode() {
        textSelectMode ? exitTextSelectMode() : enterTextSelectMode()
    }

    /// Leaves any transient mode. Picking a tool — by shortcut *or* by toolbar —
    /// has to tear these down; a live overlay left switched on would keep
    /// swallowing mouse events the drawing tools need.
    /// Host-facing wrapper: the toolbar changes tools without going through
    /// `pickTool`, so it has to tear the transient modes down itself.
    func cancelTransientModes() {
        exitTransientModes()
        updateLiveText()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func exitTransientModes() {
        if cropMode { exitCropMode() }
        if textSelectMode {
            textSelectMode = false
            liveText.clearSelection()
            onTextSelectModeChanged?(false)
        }
    }

    /// Whether an annotation covers a point given in the overlay's coordinates,
    /// so a shape drawn on top of text still wins the click.
    private func hasAnnotation(atViewPoint p: CGPoint) -> Bool {
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return false }
        let inImage = CGPoint(x: p.x * imageSize.width / r.width,
                              y: p.y * imageSize.height / r.height)
        return bodyHit(at: inImage) != nil
    }

    /// Text currently selected on the image, if any, so ⌘C can copy that rather
    /// than the image. nil on macOS 13, where the selection isn't readable.
    var selectedImageText: String? { liveText.selectedText }

    // MARK: - Crop

    func enterCropMode() {
        commitTextEditing()
        cropMode = true
        selectMode = false
        selectedIndex = nil
        cropDraft = nil
        cropDragging = false
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Leaves crop mode without changing the cursor/tool state (used when a tool
    /// shortcut switches out of cropping).
    private func exitCropMode() {
        cropMode = false
        cropDraft = nil
        cropDragging = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func cancelCrop() {
        guard cropMode else { return }
        exitCropMode()
        enterSelectMode()
    }

    func commitCrop() {
        guard cropMode else { return }
        let r = (cropDraft ?? .zero).integral
        // Too small to be a meaningful crop — treat Return as a cancel.
        guard r.width >= 1, r.height >= 1 else { cancelCrop(); return }

        // CGImage.cropping uses a top-left origin; our rect is bottom-left.
        let cgCrop = CGRect(x: r.minX, y: imageSize.height - r.maxY,
                            width: r.width, height: r.height).integral
        guard let cropped = image.cropping(to: cgCrop) else { cancelCrop(); return }

        pushUndo()
        image = cropped
        imageSize = CGSize(width: cropped.width, height: cropped.height)
        // Shift every annotation into the new (cropped) coordinate space.
        let dx = r.minX, dy = r.minY
        for i in annotations.indices {
            annotations[i].start.x -= dx; annotations[i].start.y -= dy
            annotations[i].end.x -= dx;   annotations[i].end.y -= dy
        }
        exitCropMode()
        onImageSizeChanged?(imageSize)
        enterSelectMode()
    }

    /// A normalized rect between two points, clamped to the image bounds.
    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        let x0 = clamp(min(a.x, b.x), 0, imageSize.width)
        let y0 = clamp(min(a.y, b.y), 0, imageSize.height)
        let x1 = clamp(max(a.x, b.x), 0, imageSize.width)
        let y1 = clamp(max(a.y, b.y), 0, imageSize.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    override func resetCursorRects() {
        if cropMode { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: - Hit testing

    private func handleHit(at p: CGPoint, annotation a: Annotation) -> HandleRef? {
        let tol = handleTolerance
        for (ref, pt) in handles(for: a) where abs(pt.x - p.x) <= tol && abs(pt.y - p.y) <= tol {
            return ref
        }
        return nil
    }

    private func bodyHit(at p: CGPoint) -> Int? {
        for i in annotations.indices.reversed() {
            let a = annotations[i]
            switch a.tool {
            case .arrow, .line:
                if distanceToSegment(p, a.start, a.end) <= max(a.lineWidth, 8 / scale) { return i }
            case .text:
                if textRect(for: a).insetBy(dx: -6 / scale, dy: -6 / scale).contains(p) { return i }
            default:
                if rect(for: a).insetBy(dx: -6 / scale, dy: -6 / scale).contains(p) { return i }
            }
        }
        return nil
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        if dx == 0 && dy == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy), 0, 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Control points

    private func handles(for a: Annotation) -> [(HandleRef, CGPoint)] {
        switch a.tool {
        case .text:
            return []  // text is move-only
        case .arrow, .line:
            return [(.arrowStart, a.start), (.arrowEnd, a.end)]
        default:
            let r = rect(for: a)
            let xs: [(Axis, CGFloat)] = [(.lo, r.minX), (.mid, r.midX), (.hi, r.maxX)]
            let ys: [(Axis, CGFloat)] = [(.lo, r.minY), (.mid, r.midY), (.hi, r.maxY)]
            var out: [(HandleRef, CGPoint)] = []
            for (ax, xv) in xs {
                for (ay, yv) in ys where !(ax == .mid && ay == .mid) {
                    out.append((.rect(x: ax, y: ay), CGPoint(x: xv, y: yv)))
                }
            }
            return out
        }
    }

    private func applyResize(_ a: inout Annotation, ref: HandleRef, to p: CGPoint) {
        switch ref {
        case .arrowStart:
            a.start = p
        case .arrowEnd:
            a.end = p
        case .rect(let ax, let ay):
            let minSize: CGFloat = 4
            var minX = min(a.start.x, a.end.x), maxX = max(a.start.x, a.end.x)
            var minY = min(a.start.y, a.end.y), maxY = max(a.start.y, a.end.y)
            switch ax {
            case .lo: minX = min(p.x, maxX - minSize)
            case .hi: maxX = max(p.x, minX + minSize)
            case .mid: break
            }
            switch ay {
            case .lo: minY = min(p.y, maxY - minSize)
            case .hi: maxY = max(p.y, minY + minSize)
            case .mid: break
            }
            a.start = CGPoint(x: minX, y: minY)
            a.end = CGPoint(x: maxX, y: maxY)
        }
    }

    // MARK: - Text metrics

    private func fontSize(for a: Annotation) -> CGFloat { max(8, a.fontSize) }

    private func textFont(for a: Annotation) -> NSFont {
        NSFont.systemFont(ofSize: fontSize(for: a), weight: .semibold)
    }

    /// Text split into individual lines. Always at least one (possibly empty)
    /// line, so an empty box or a trailing newline still has a caret row.
    private func textLines(of a: Annotation) -> [String] {
        a.text.components(separatedBy: "\n")
    }

    private func ctLine(_ string: String, for a: Annotation) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont(for: a),
            .foregroundColor: a.color,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): a.color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
    }

    private func lineWidth(_ string: String, for a: Annotation) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(ctLine(string, for: a), nil, nil, nil))
    }

    /// Layout metrics for a (possibly multi-line) text annotation, in image px.
    private func textMetrics(_ a: Annotation) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat, lineHeight: CGFloat, height: CGFloat) {
        let font = textFont(for: a)
        let ascent = font.ascender
        let descent = -font.descender
        let lineHeight = ascent + descent + font.leading
        let lines = textLines(of: a)
        let width = lines.map { lineWidth($0, for: a) }.max() ?? 0
        return (width, ascent, descent, lineHeight, lineHeight * CGFloat(lines.count))
    }

    /// Bounding box of a text annotation, anchored with its top-left at `start`.
    private func textRect(for a: Annotation) -> CGRect {
        let m = textMetrics(a)
        return CGRect(x: a.start.x, y: a.start.y - m.height,
                      width: max(m.width, 8), height: m.height)
    }

    // MARK: - Display

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor(white: 0.12, alpha: 1).setFill()
        ctx.fill(bounds)

        let r = imageRect
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)

        // Annotations are drawn in image space, scaled into the on-screen rect.
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        for a in annotations { render(a, into: ctx) }
        if let d = draft { render(d, into: ctx) }
        if let ei = editingTextIndex, ei < annotations.count {
            drawCaret(annotations[ei], into: ctx)
        }
        ctx.restoreGState()

        // Selection chrome is drawn in view space so handles stay a constant size.
        if selectMode, let i = selectedIndex, i < annotations.count {
            drawSelection(annotations[i], into: ctx)
        }

        if cropMode { drawCropOverlay(into: ctx) }
    }

    /// Dims the image outside the crop selection and draws its border + a hint.
    private func drawCropOverlay(into ctx: CGContext) {
        let r = imageRect
        ctx.saveGState()
        if let d = cropDraft, d.width > 0, d.height > 0 {
            let p0 = imageToView(CGPoint(x: d.minX, y: d.minY))
            let p1 = imageToView(CGPoint(x: d.maxX, y: d.maxY))
            let vr = CGRect(x: p0.x, y: p0.y, width: p1.x - p0.x, height: p1.y - p0.y)
            // Dim everything but the selection (even-odd: image rect minus crop).
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addRect(r); ctx.addRect(vr)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(vr)
        } else {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.fill(r)
        }
        ctx.restoreGState()
        drawCropHint()
    }

    private func drawCropHint() {
        let text = "Drag to select  ·  Return to crop  ·  Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let pad: CGFloat = 8
        let box = CGRect(x: (bounds.width - sz.width) / 2 - pad,
                         y: bounds.height - sz.height - 16 - pad,
                         width: sz.width + pad * 2, height: sz.height + pad * 2)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        s.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad))
    }

    private func drawSelection(_ a: Annotation, into ctx: CGContext) {
        let accent = NSColor.controlAccentColor

        if a.tool != .arrow && a.tool != .line {
            let r = (a.tool == .text) ? textRect(for: a) : rect(for: a)
            let p0 = imageToView(CGPoint(x: r.minX, y: r.minY))
            let p1 = imageToView(CGPoint(x: r.maxX, y: r.maxY))
            let vr = CGRect(x: p0.x, y: p0.y, width: p1.x - p0.x, height: p1.y - p0.y)
                .insetBy(dx: -2, dy: -2)
            ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(vr)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        for (_, pt) in handles(for: a) {
            let v = imageToView(pt)
            let box = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.fill(box)
            ctx.stroke(box)
        }
    }

    private func drawCaret(_ a: Annotation, into ctx: CGContext) {
        guard a.tool == .text else { return }
        let m = textMetrics(a)
        let lines = textLines(of: a)
        let last = lines.count - 1
        let x = a.start.x + lineWidth(lines[last], for: a) + 1
        let baseline = a.start.y - m.ascent - CGFloat(last) * m.lineHeight
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(max(1.5, fontSize(for: a) * 0.06))
        ctx.move(to: CGPoint(x: x, y: baseline - m.descent))
        ctx.addLine(to: CGPoint(x: x, y: baseline + m.ascent))
        ctx.strokePath()
    }

    // MARK: - Rendering (image-pixel coordinates)

    private func rect(for a: Annotation) -> CGRect {
        CGRect(x: min(a.start.x, a.end.x),
               y: min(a.start.y, a.end.y),
               width: abs(a.end.x - a.start.x),
               height: abs(a.end.y - a.start.y))
    }

    private func render(_ a: Annotation, into ctx: CGContext) {
        ctx.saveGState()
        switch a.tool {
        case .rectangle:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.stroke(rect(for: a))
        case .ellipse:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokeEllipse(in: rect(for: a))
        case .arrow:
            drawArrow(from: a.start, to: a.end, color: a.color, width: a.lineWidth, into: ctx)
        case .line:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .box:
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect(for: a))
        case .blur:
            pixelate(rect(for: a), into: ctx)
        case .text:
            drawText(a, into: ctx)
        }
        ctx.restoreGState()
    }

    private func drawText(_ a: Annotation, into ctx: CGContext) {
        let m = textMetrics(a)
        ctx.saveGState()
        ctx.textMatrix = .identity
        for (i, s) in textLines(of: a).enumerated() where !s.isEmpty {
            let baseline = a.start.y - m.ascent - CGFloat(i) * m.lineHeight
            ctx.textPosition = CGPoint(x: a.start.x, y: baseline)
            CTLineDraw(ctLine(s, for: a), ctx)
        }
        ctx.restoreGState()
    }

    private func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat, into ctx: CGContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLen = max(width * 3.5, 14)

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)

        // Stop the shaft short of the tip so it doesn't poke through the head.
        let shaftEnd = CGPoint(x: to.x - cos(angle) * headLen * 0.7,
                               y: to.y - sin(angle) * headLen * 0.7)
        ctx.move(to: from)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let left = angle + .pi - 0.45
        let right = angle + .pi + 0.45
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x + cos(left) * headLen, y: to.y + sin(left) * headLen))
        ctx.addLine(to: CGPoint(x: to.x + cos(right) * headLen, y: to.y + sin(right) * headLen))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Pixelates a region by sampling the source image, downscaling, then
    /// drawing back with nearest-neighbor so each block is a flat color.
    private func pixelate(_ rect: CGRect, into ctx: CGContext) {
        let intRect = rect.integral
        guard intRect.width >= 1, intRect.height >= 1 else { return }

        // CGImage.cropping uses a top-left origin, so flip the y of our
        // bottom-left rect into the image's coordinate space.
        let cropRect = CGRect(x: intRect.minX,
                              y: imageSize.height - intRect.maxY,
                              width: intRect.width,
                              height: intRect.height).integral
        guard let sub = image.cropping(to: cropRect) else { return }

        let blocks: CGFloat = 16
        let longSide = max(intRect.width, intRect.height)
        let smallW = max(1, Int(intRect.width / longSide * blocks))
        let smallH = max(1, Int(intRect.height / longSide * blocks))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let small = CGContext(data: nil, width: smallW, height: smallH,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(sub, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let pixelated = small.makeImage() else { return }

        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(pixelated, in: rect)
        ctx.restoreGState()
    }

    // MARK: - Export

    /// Flattens the image plus all annotations into a full-resolution CGImage.
    func compositeImage() -> CGImage? {
        commitTextEditing()
        let w = image.width, h = image.height
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for a in annotations { render(a, into: ctx) }
        return ctx.makeImage()
    }
}
