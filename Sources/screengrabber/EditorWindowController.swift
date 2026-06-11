import AppKit
import UniformTypeIdentifiers

/// Hosts the annotation toolbar and canvas in a single window.
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let canvas: CanvasView
    private let colorWell = NSColorWell()

    /// If set, the composited image is written here when the window closes
    /// (auto-save). The raw capture was already written here at capture time.
    private let autoSaveURL: URL?
    private let onOpenPreferences: (() -> Void)?

    /// Called when the window closes, so the app delegate can drop its reference.
    var onClose: (() -> Void)?

    init(image: CGImage, autoSaveURL: URL?, onOpenPreferences: (() -> Void)?) {
        self.canvas = CanvasView(image: image)
        self.autoSaveURL = autoSaveURL
        self.onOpenPreferences = onOpenPreferences

        let toolbarHeight: CGFloat = 44
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.9
        let maxH = screen.height * 0.9 - toolbarHeight
        let fit = min(1, min(maxW / CGFloat(image.width), maxH / CGFloat(image.height)))
        let contentW = max(820, CGFloat(image.width) * fit)
        let contentH = CGFloat(image.height) * fit + toolbarHeight

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "ScreenGrabber"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 360)
        window.center()

        super.init(window: window)
        window.delegate = self
        buildContent(toolbarHeight: toolbarHeight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func buildContent(toolbarHeight: CGFloat) {
        let content = NSView()

        let tools = makeToolControl()

        // After drawing a shape, auto-switch to Select mode to adjust it.
        canvas.onDrawFinished = { [weak self, weak tools] in
            tools?.selectedSegment = 0
            self?.canvas.selectMode = true
        }
        // Keyboard tool shortcuts keep the toolbar highlight in sync.
        canvas.onToolPicked = { [weak tools] segment in tools?.selectedSegment = segment }
        canvas.onOpenPreferences = onOpenPreferences

        // Start on the user's default tool (nil = Select mode, no drawing).
        if let tool = Preferences.shared.defaultTool {
            canvas.selectMode = false
            canvas.currentTool = tool
            tools.selectedSegment = (Tool.paletteOrder.firstIndex(of: tool) ?? 0) + 1
        } else {
            canvas.selectMode = true
            tools.selectedSegment = 0
        }

        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 28,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        widthSlider.toolTip = "Stroke width"

        let sizeLabel = NSTextField(labelWithString: "Aa")
        sizeLabel.textColor = .secondaryLabelColor
        let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePopup.addItems(withTitles: ["12", "16", "20", "28", "36", "48", "64"])
        sizePopup.selectItem(withTitle: "28")
        sizePopup.target = self
        sizePopup.action = #selector(fontSizeChanged(_:))
        sizePopup.toolTip = "Text size"
        sizePopup.translatesAutoresizingMaskIntoConstraints = false
        sizePopup.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let undo = makeButton("Undo", action: #selector(undo(_:)), key: "z")
        let clear = makeButton("Clear", action: #selector(clearAll(_:)), key: "")
        let save = makeButton("Save…", action: #selector(save(_:)), key: "s")
        let copy = makeButton("Copy", action: #selector(copyToClipboard(_:)), key: "c")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [tools, sizeLabel, sizePopup, colorWell, widthSlider,
                                      spacer, undo, clear, save, copy])
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
        window?.makeFirstResponder(canvas)
    }

    private func makeToolControl() -> NSSegmentedControl {
        let tools = NSSegmentedControl()
        let palette = Tool.paletteOrder
        tools.segmentCount = palette.count + 1   // + Select at segment 0
        tools.trackingMode = .selectOne
        tools.target = self
        tools.action = #selector(toolChanged(_:))

        // Segment 0 is Select (shortcut "1"); the rest follow Tool.paletteOrder,
        // with number shortcuts "2"… (Text keeps "T").
        tools.setImage(NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Select"), forSegment: 0)
        tools.setToolTip("Select (1)", forSegment: 0)
        tools.setWidth(36, forSegment: 0)
        for (i, tool) in palette.enumerated() {
            let seg = i + 1
            let key = (tool == .text) ? "T" : "\(i + 2)"
            tools.setImage(NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.displayName),
                           forSegment: seg)
            tools.setToolTip("\(tool.displayName) (\(key))", forSegment: seg)
            tools.setWidth(36, forSegment: seg)
        }
        return tools
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
        // Segment 0 is Select mode; the rest map to Tool.paletteOrder (offset by one).
        if sender.selectedSegment == 0 {
            canvas.selectMode = true
        } else {
            canvas.selectMode = false
            canvas.currentTool = Tool.paletteOrder[sender.selectedSegment - 1]
        }
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.currentColor = sender.color
        canvas.setSelectedColor(sender.color)   // retarget the selected shape too
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.currentLineWidth = CGFloat(sender.doubleValue)
        canvas.setSelectedLineWidth(CGFloat(sender.doubleValue))
    }

    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        let size = CGFloat(Int(sender.titleOfSelectedItem ?? "28") ?? 28)
        canvas.currentFontSize = size
        canvas.setSelectedFontSize(size)
    }

    @objc private func undo(_ sender: Any?) { canvas.undo() }
    @objc private func clearAll(_ sender: Any?) { canvas.clearAll() }

    @objc private func copyToClipboard(_ sender: Any?) {
        guard let cg = canvas.compositeImage() else { return }
        copyImageToClipboard(cg)
        flashTitle("Copied to clipboard ✓")
    }

    @objc private func save(_ sender: Any?) {
        guard let cg = canvas.compositeImage(), let window = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.nameFieldStringValue = Preferences.shared.previewFilename()
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
        // Update the auto-saved file with the final annotated image.
        if let url = autoSaveURL, let cg = canvas.compositeImage() {
            writePNG(cg, to: url)
        }
        onClose?()
    }
}
