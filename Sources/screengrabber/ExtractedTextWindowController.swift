import AppKit

/// The panel's content view, which exists only to route the find shortcuts.
///
/// `NSTextView.usesFindBar` supplies the whole find UI, but nothing *triggers*
/// it: AppKit drives finding from the Edit ▸ Find menu items, and this is an
/// `LSUIElement` app with no menu bar (the same reason ⌘W and ⌘O are wired by
/// hand in `CanvasView.performKeyEquivalent`). Each action is dispatched by
/// handing the text view a sender whose `tag` is an `NSTextFinder.Action` —
/// that tag-on-the-sender protocol is how AppKit's find actions identify
/// themselves.
private final class FindableContentView: NSView {

    weak var textView: NSTextView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let textView = textView,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = flags.contains(.shift)

        let action: NSTextFinder.Action
        switch key {
        case "f":  action = .showFindInterface
        case "g":  action = shift ? .previousMatch : .nextMatch
        case "e":  action = .setSearchString
        default:   return super.performKeyEquivalent(with: event)
        }
        // ⇧⌘F isn't a find shortcut; let it fall through rather than swallowing it.
        if key == "f" && shift { return super.performKeyEquivalent(with: event) }

        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
        return true
    }
}

/// A floating panel showing the text OCR'd out of the current image, in a
/// selectable text view. One instance per editor window, reused across repeat
/// invocations — each call to `show(text:relativeTo:)` re-runs recognition, so
/// the panel always reflects the image as it is now (post-crop, post-redaction).
final class ExtractedTextWindowController: NSWindowController, NSTextViewDelegate {

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let copyButton: NSButton

    /// Bumped on every `show(...)` so a slow recognition that finishes after a
    /// newer one was started is discarded instead of clobbering it.
    private var generation = 0

    init() {
        copyButton = NSButton(title: "Copy All", target: nil, action: nil)

        // Wider than it looks like it needs to be: at 14pt monospace a narrower
        // panel wraps typical recognized lines.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Extracted Text"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        // NSPanel hides itself on deactivation by default — which would make the
        // panel disappear the moment you switched to the app you're pasting into.
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 280, height: 200)

        super.init(window: panel)

        copyButton.target = self
        copyButton.action = #selector(copyAll(_:))
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func buildContent() {
        let content = FindableContentView()
        content.textView = textView

        // Editable: OCR is very good but not perfect, and fixing a stray character
        // in place beats pasting somewhere else and fixing it there.
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // Substitutions and autocorrect would quietly corrupt recognized code,
        // paths, and URLs — exactly the text people come here to grab.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        // The standard find bar, which draws itself inside the enclosing scroll
        // view — so ⌘F costs no layout of ours. See FindableContentView for why
        // the shortcut still has to be wired by hand.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Shown in place of the text while recognizing, and when nothing was found.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // No menu bar in an accessory app, so ⌘F has nowhere else to advertise itself.
        countLabel.toolTip = "⌘F to find · ⌘G / ⇧⌘G for next / previous match"

        let close = NSButton(title: "Close", target: self, action: #selector(closePanel(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"   // Esc

        // Deliberately no ⌘C here: a button key equivalent is offered the event
        // before the responder chain, so binding ⌘C would steal it from the text
        // view and break copying a *selection*.
        copyButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [countLabel, spacer, close, copyButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(spinner)
        content.addSubview(statusLabel)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        window?.contentView = content
        // Deliberately no default button: Return has to reach the (editable) text
        // view to insert a newline, and a default button is offered key events
        // first. Copy All is click-only; ⌘A then ⌘C is the keyboard route.
    }

    // MARK: - Recognition

    /// Runs OCR on `image` and shows the panel, parked to the right of `parent`.
    func show(text image: CGImage, relativeTo parent: NSWindow) {
        generation += 1
        let token = generation

        setState(.recognizing)
        position(relativeTo: parent)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)

        TextRecognizer.recognize(in: image) { [weak self] text in
            guard let self = self, token == self.generation else { return }
            self.setState(text.isEmpty ? .empty : .loaded(text))
        }
    }

    private enum State {
        case recognizing, empty, loaded(String)
    }

    private func setState(_ state: State) {
        switch state {
        case .recognizing:
            // Both hidden states hide the scroll view, which would strand an open
            // find bar (and its stale search) inside it.
            hideFindBar()
            textView.string = ""
            scrollView.isHidden = true
            statusLabel.stringValue = "Recognizing text…"
            statusLabel.isHidden = false
            spinner.startAnimation(nil)
            countLabel.stringValue = ""
            copyButton.isEnabled = false

        case .empty:
            hideFindBar()
            scrollView.isHidden = true
            spinner.stopAnimation(nil)
            statusLabel.stringValue = "No text found."
            statusLabel.isHidden = false
            countLabel.stringValue = ""
            copyButton.isEnabled = false

        case .loaded(let text):
            spinner.stopAnimation(nil)
            statusLabel.isHidden = true
            scrollView.isHidden = false
            textView.string = text
            textView.scroll(NSPoint(x: 0, y: 0))
            countLabel.stringValue = summary(of: text)
            copyButton.isEnabled = true
            // So ⌘A / ⌘C work without having to click into the text first — but
            // not while the find bar is up, or a re-run would yank the caret out
            // of the search field mid-typing.
            if !scrollView.isFindBarVisible { window?.makeFirstResponder(textView) }
        }
    }

    private func hideFindBar() {
        guard scrollView.isFindBarVisible else { return }
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.hideFindInterface.rawValue
        textView.performTextFinderAction(sender)
    }

    private func summary(of text: String) -> String {
        let lines = text.split(separator: "\n").count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return "\(lines) line\(lines == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s")"
    }

    /// Parks the panel just right of the editor window, clamped onto the screen.
    /// The editor is usually near screen-width, so in practice this lands the
    /// panel against the right edge, overlapping the editor rather than hiding
    /// off-screen or covering the middle of the image.
    private func position(relativeTo parent: NSWindow) {
        guard let window = window, !window.isVisible else { return }
        let visible = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let x = min(parent.frame.maxX + 12, visible.maxX - size.width - 12)
        let y = min(parent.frame.maxY - size.height, visible.maxY - size.height - 12)
        window.setFrameOrigin(NSPoint(x: max(visible.minX + 12, x),
                                      y: max(visible.minY + 12, y)))
    }

    // MARK: - Actions

    /// Copies what's in the box now, edits included — not the raw recognition.
    @objc private func copyAll(_ sender: Any?) {
        let text = textView.string
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashTitle("Copied ✓")
    }

    @objc private func closePanel(_ sender: Any?) { window?.close() }

    // MARK: - NSTextViewDelegate

    /// Keeps the counter and the Copy All button honest while the text is edited.
    func textDidChange(_ notification: Notification) {
        countLabel.stringValue = summary(of: textView.string)
        copyButton.isEnabled = !textView.string.isEmpty
    }

    private func flashTitle(_ message: String) {
        guard let window = window else { return }
        let original = window.title
        window.title = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak window] in
            window?.title = original
        }
    }
}
