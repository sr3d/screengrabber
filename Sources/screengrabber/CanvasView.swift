import AppKit
import CoreText

enum Tool: Int {
    case arrow = 0
    case rectangle
    case ellipse
    case blur
    case box
    case text
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
    var text: String = ""   // used by the .text tool only
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

    private let image: CGImage
    private let imageSize: CGSize

    private(set) var annotations: [Annotation] = []
    private var draft: Annotation?

    var currentTool: Tool = .arrow
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 4

    /// When true, clicks select / move / resize existing shapes instead of
    /// drawing new ones.
    var selectMode = false {
        didSet { needsDisplay = true }
    }
    private(set) var selectedIndex: Int?
    private var editingTextIndex: Int?

    /// Called after a drag-drawn shape is committed, so the host can flip the
    /// toolbar into Select mode (the new shape is already selected).
    var onDrawFinished: (() -> Void)?

    private var activeDrag: Drag = .none
    private var moveFrom: CGPoint = .zero
    private var moveOrigStart: CGPoint = .zero
    private var moveOrigEnd: CGPoint = .zero

    init(image: CGImage) {
        self.image = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
        wantsLayer = true
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
            let a = Annotation(tool: .text, start: p, end: p,
                               color: currentColor, lineWidth: currentLineWidth)
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
        let p = imagePoint(from: event)
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
        var didDraw = false
        if case .drawing = activeDrag, var d = draft {
            d.end = imagePoint(from: event)
            if hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 2 {
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
        if let i = editingTextIndex, i < annotations.count {
            switch event.keyCode {
            case 36, 76:       // return / enter -> newline (⌘Return commits)
                if event.modifierFlags.contains(.command) {
                    commitTextEditing()
                } else {
                    annotations[i].text.append("\n")
                }
            case 53:           // escape -> commit
                commitTextEditing()
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

        // 51 = delete/backspace, 117 = forward delete.
        if (event.keyCode == 51 || event.keyCode == 117), let i = selectedIndex {
            annotations.remove(at: i)
            selectedIndex = nil
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    private func commitTextEditing() {
        guard let i = editingTextIndex else { return }
        editingTextIndex = nil
        // Drop an empty text box that was never typed into.
        if i < annotations.count && annotations[i].text.isEmpty {
            annotations.remove(at: i)
            if selectedIndex == i { selectedIndex = nil }
            else if let s = selectedIndex, s > i { selectedIndex = s - 1 }
        }
        needsDisplay = true
    }

    // MARK: - Editing actions

    func undo() {
        guard !annotations.isEmpty else { return }
        editingTextIndex = nil
        annotations.removeLast()
        selectedIndex = nil
        needsDisplay = true
    }

    func clearAll() {
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
            case .arrow:
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
        case .arrow:
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

    private func fontSize(for a: Annotation) -> CGFloat { max(18, a.lineWidth * 5) }

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
    }

    private func drawSelection(_ a: Annotation, into ctx: CGContext) {
        let accent = NSColor.controlAccentColor

        if a.tool != .arrow {
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
