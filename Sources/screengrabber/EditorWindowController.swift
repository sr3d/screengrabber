import AppKit
import UniformTypeIdentifiers

/// Hosts the annotation toolbar and canvas in a single window.
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let canvas: CanvasView
    private let colorWell = NSColorWell()
    /// The Live Text toggle, kept so the canvas can un-press it when the mode
    /// ends by some other route (Esc, or picking a tool).
    private var selectText = NSButton()

    /// If set, the composited image is written here when the window closes
    /// (auto-save). The raw capture was already written here at capture time.
    private let autoSaveURL: URL?
    private let onOpenPreferences: (() -> Void)?
    private let onOpenImage: (() -> Void)?

    /// On-disk file backing this capture, used by Copy File / Reveal File.
    /// Starts as the auto-save URL; if auto-save is off, a file is created on
    /// first use so there's always something to copy or reveal.
    private var savedFileURL: URL?

    /// The Extracted Text panel, created on first use and reused after that.
    private var extractedTextPanel: ExtractedTextWindowController?

    /// Called when the window closes, so the app delegate can drop its reference.
    var onClose: (() -> Void)?

    private let toolbarHeight: CGFloat = 44

    init(image: CGImage, autoSaveURL: URL?, onOpenPreferences: (() -> Void)?,
         onOpenImage: (() -> Void)? = nil) {
        self.canvas = CanvasView(image: image)
        self.autoSaveURL = autoSaveURL
        self.savedFileURL = autoSaveURL
        self.onOpenPreferences = onOpenPreferences
        self.onOpenImage = onOpenImage

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

    /// Resizes the window to fit a new base-image size (after a crop or its undo),
    /// keeping the top-left corner anchored.
    private func resizeToFit(imageSize: CGSize) {
        guard let window = window, imageSize.width > 0, imageSize.height > 0 else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.9
        let maxH = screen.height * 0.9 - toolbarHeight
        let fit = min(1, min(maxW / imageSize.width, maxH / imageSize.height))
        let contentW = max(820, imageSize.width * fit)
        let contentH = imageSize.height * fit + toolbarHeight

        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        frame.origin.x = old.minX
        frame.origin.y = old.maxY - frame.height   // keep the top edge fixed
        window.setFrame(frame, display: true, animate: true)
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
        canvas.onOpenImage = onOpenImage
        // A crop (or undoing one) changes the image size; refit the window.
        canvas.onImageSizeChanged = { [weak self] size in self?.resizeToFit(imageSize: size) }
        canvas.onTextSelectModeChanged = { [weak self] on in
            self?.selectText.state = on ? .on : .off
        }

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

        let crop = makeButton("Crop", action: #selector(cropImage(_:)), key: "")
        if let cropImg = NSImage(systemSymbolName: "crop", accessibilityDescription: "Crop") {
            crop.image = cropImg
            crop.imagePosition = .imageOnly   // icon-only keeps the toolbar compact
        }
        crop.toolTip = "Crop: drag a region, Return to apply, Esc to cancel"

        // Labelled rather than icon-only (unlike Crop): "OCR" isn't something you
        // guess from a glyph, and it's the one toolbar action whose result opens
        // a separate window.
        let extractText = makeButton("OCR", action: #selector(extractText(_:)),
                                     key: "t", modifiers: [.command, .shift])
        if let ocrImg = NSImage(systemSymbolName: "text.viewfinder",
                                accessibilityDescription: "OCR") {
            extractText.image = ocrImg
            extractText.imagePosition = .imageLeading
        }
        extractText.toolTip = "OCR: extract the text from this image into a selectable panel (⇧⌘T)"

        selectText = makeButton("Select Text", action: #selector(toggleSelectText(_:)),
                                key: "l", modifiers: [.command, .shift])
        selectText.setButtonType(.pushOnPushOff)
        if let img = NSImage(systemSymbolName: "character.cursor.ibeam",
                             accessibilityDescription: "Select Text") {
            selectText.image = img
            selectText.imagePosition = .imageLeading
        }
        if LiveTextOverlay.isSupported {
            selectText.toolTip = "Select Text: drag to select text on the image itself (⇧⌘L). "
                + "In Select mode this also happens automatically when you hover over text."
        } else {
            // Live Text needs Apple silicon; the OCR panel still works everywhere.
            selectText.isEnabled = false
            selectText.toolTip = "Select Text needs an Apple silicon Mac. Use OCR (⇧⌘T) instead."
        }

        let undo = makeButton("Undo", action: #selector(undo(_:)), key: "z")
        let clear = makeButton("Clear", action: #selector(clearAll(_:)), key: "")
        let saveSplit = makeSaveSplitButton()
        let copy = makeButton("Copy", action: #selector(copyToClipboard(_:)), key: "c")
        let copyFile = makeButton("Copy File", action: #selector(copyFile(_:)), key: "c",
                                  modifiers: [.command, .shift])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [tools, crop, extractText, selectText, sizeLabel, sizePopup,
                                      colorWell, widthSlider, spacer, undo, clear, saveSplit,
                                      copy, copyFile])
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

    private func makeButton(_ title: String, action: Selector, key: String,
                            modifiers: NSEvent.ModifierFlags = .command) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if !key.isEmpty {
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = modifiers
        }
        return b
    }

    /// "Save…" with an attached chevron that drops a menu (Reveal File).
    private func makeSaveSplitButton() -> NSStackView {
        let save = makeButton("Save…", action: #selector(save(_:)), key: "s")

        let chevron = NSButton(title: "", target: self, action: #selector(showSaveMenu(_:)))
        chevron.bezelStyle = .rounded
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More")
        chevron.imagePosition = .imageOnly
        chevron.toolTip = "More save options"
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let split = NSStackView(views: [save, chevron])
        split.orientation = .horizontal
        split.spacing = 1
        return split
    }

    @objc private func showSaveMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let reveal = NSMenuItem(title: "Reveal File in Finder",
                                action: #selector(revealFile(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: - Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        // Picking a tool leaves crop / text-select. Previously crop mode survived
        // this and stayed stuck on; with a Live Text overlay it would also keep
        // swallowing the clicks the tool needs.
        canvas.cancelTransientModes()
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
    @objc private func cropImage(_ sender: Any?) { canvas.enterCropMode() }

    /// OCRs the image and opens the Extracted Text panel. Recognition runs on the
    /// *composite*, so it follows any crop and — deliberately — cannot resurrect
    /// text the user blurred or boxed out.
    @objc private func extractText(_ sender: Any?) {
        guard let cg = canvas.compositeImage(), let window = window else { return }
        let panel = extractedTextPanel ?? ExtractedTextWindowController()
        extractedTextPanel = panel
        panel.show(text: cg, relativeTo: window)
    }

    @objc private func toggleSelectText(_ sender: Any?) {
        canvas.toggleTextSelectMode()
        selectText.state = canvas.textSelectMode ? .on : .off
    }

    /// ⌘C copies the image — unless text is selected on the image itself, in which
    /// case it copies that. A button's key equivalent is offered before the
    /// responder chain, so without this the toolbar's Copy would always win over
    /// the Live Text overlay's own ⌘C.
    @objc private func copyToClipboard(_ sender: Any?) {
        if let text = canvas.selectedImageText {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            flashTitle("Text copied ✓")
            return
        }
        guard let cg = canvas.compositeImage() else { return }
        copyImageToClipboard(cg)
        flashTitle("Copied to clipboard ✓")
    }

    /// Puts the current image's file URL on the pasteboard so it can be pasted
    /// into another folder in Finder (not the pixels — the file itself).
    @objc private func copyFile(_ sender: Any?) {
        guard let url = currentFileOnDisk() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        flashTitle("File copied ✓")
    }

    /// Opens a Finder window with the current image's file selected.
    @objc private func revealFile(_ sender: Any?) {
        guard let url = currentFileOnDisk() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Writes the current composite to disk and returns its URL. Reuses the
    /// auto-save file when present; otherwise creates one on first use.
    private func currentFileOnDisk() -> URL? {
        guard let cg = canvas.compositeImage() else { return nil }
        let url = savedFileURL ?? Preferences.shared.makeFileURL()
        guard writePNG(cg, to: url) else { return nil }
        savedFileURL = url
        Preferences.shared.addRecentFile(url)
        return url
    }

    @objc private func save(_ sender: Any?) {
        guard let cg = canvas.compositeImage(), let window = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.nameFieldStringValue = Preferences.shared.previewFilename()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                // Point Copy File / Reveal File at where the user just saved.
                self?.savedFileURL = url
                Preferences.shared.addRecentFile(url)
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
        // The text panel belongs to this editor; don't let it outlive the window.
        extractedTextPanel?.close()
        extractedTextPanel = nil

        // Update the auto-saved file with the final annotated image.
        if let url = autoSaveURL, let cg = canvas.compositeImage() {
            writePNG(cg, to: url)
            Preferences.shared.addRecentFile(url)
        }
        onClose?()
    }
}
