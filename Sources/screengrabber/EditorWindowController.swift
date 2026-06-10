import AppKit
import UniformTypeIdentifiers

/// Hosts the annotation toolbar and canvas in a single window.
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let canvas: CanvasView
    private let colorWell = NSColorWell()

    /// Called when the window closes, so the app delegate can drop its reference.
    var onClose: (() -> Void)?

    init(image: CGImage) {
        canvas = CanvasView(image: image)

        let toolbarHeight: CGFloat = 44
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.9
        let maxH = screen.height * 0.9 - toolbarHeight
        let fit = min(1, min(maxW / CGFloat(image.width), maxH / CGFloat(image.height)))
        let contentW = max(560, CGFloat(image.width) * fit)
        let contentH = CGFloat(image.height) * fit + toolbarHeight

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "ScreenGrabber"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.center()

        super.init(window: window)
        window.delegate = self
        buildContent(toolbarHeight: toolbarHeight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func buildContent(toolbarHeight: CGFloat) {
        let content = NSView()

        let tools = NSSegmentedControl(labels: ["→ Arrow", "▢ Rect", "◯ Circle", "▦ Blur", "■ Box"],
                                       trackingMode: .selectOne,
                                       target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0

        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 28,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let undo = makeButton("Undo", action: #selector(undo(_:)), key: "z")
        let clear = makeButton("Clear", action: #selector(clearAll(_:)), key: "")
        let save = makeButton("Save…", action: #selector(save(_:)), key: "s")
        let copy = makeButton("Copy", action: #selector(copyToClipboard(_:)), key: "c")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [tools, colorWell, widthSlider, spacer, undo, clear, save, copy])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false

        canvas.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(bar)
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window?.contentView = content
    }

    private func makeButton(_ title: String, action: Selector, key: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if !key.isEmpty {
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = .command
        }
        return b
    }

    // MARK: - Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.currentTool = Tool(rawValue: sender.selectedSegment) ?? .arrow
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.currentColor = sender.color
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.currentLineWidth = CGFloat(sender.doubleValue)
    }

    @objc private func undo(_ sender: Any?) { canvas.undo() }
    @objc private func clearAll(_ sender: Any?) { canvas.clearAll() }

    @objc private func copyToClipboard(_ sender: Any?) {
        guard let cg = canvas.compositeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        let pb = NSPasteboard.general
        pb.clearContents()
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        pb.writeObjects([nsImage])
        // Also expose PNG explicitly; some apps (incl. Slack) prefer it over TIFF.
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        flashTitle("Copied to clipboard ✓")
    }

    @objc private func save(_ sender: Any?) {
        guard let cg = canvas.compositeImage(), let window = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot.png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
        }
    }

    private func flashTitle(_ message: String) {
        guard let window = window else { return }
        let original = window.title
        window.title = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak window] in
            window?.title = original
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
