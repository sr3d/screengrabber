import AppKit

enum Tool: Int {
    case arrow = 0
    case rectangle
    case ellipse
    case blur
    case box
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
}

/// The drawing surface. It letterboxes the captured image to fit, maps mouse
/// input into image-pixel space, and composites annotations over the image.
final class CanvasView: NSView {
    private let image: CGImage
    private let imageSize: CGSize

    private(set) var annotations: [Annotation] = []
    private var draft: Annotation?

    var currentTool: Tool = .arrow
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 4

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
        let scale = min(bw / imageSize.width, bh / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (bw - w) / 2, y: (bh - h) / 2, width: w, height: h)
    }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return .zero }
        let x = (v.x - r.minX) * imageSize.width / r.width
        let y = (v.y - r.minY) * imageSize.height / r.height
        return CGPoint(x: min(max(x, 0), imageSize.width),
                       y: min(max(y, 0), imageSize.height))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = imagePoint(from: event)
        draft = Annotation(tool: currentTool, start: p, end: p,
                           color: currentColor, lineWidth: currentLineWidth)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        draft?.end = imagePoint(from: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if var d = draft {
            d.end = imagePoint(from: event)
            if hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 2 {
                annotations.append(d)
            }
        }
        draft = nil
        needsDisplay = true
    }

    // MARK: - Editing actions

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    func clearAll() {
        annotations.removeAll()
        needsDisplay = true
    }

    // MARK: - Display

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor(white: 0.12, alpha: 1).setFill()
        ctx.fill(bounds)

        let r = imageRect
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)

        // Draw annotations in image space, scaled into the on-screen image rect.
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: r.width / imageSize.width, y: r.height / imageSize.height)
        for a in annotations { render(a, into: ctx) }
        if let d = draft { render(d, into: ctx) }
        ctx.restoreGState()
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
