import AppKit
import Carbon

private let repoURL = "https://github.com/sr3d/macos-screengrabber"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let capture = CaptureController()
    private var editors: [EditorWindowController] = []
    private var capturing = false
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // ⇧⌘4 — kVK_ANSI_4 is 0x15. Disable the macOS built-in shortcut in
        // System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Screenshots so this
        // one wins.
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_4),
                                     modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.beginCapture()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = AppDelegate.menuBarIcon()
        }

        let menu = NSMenu()
        let capItem = NSMenuItem(title: "Capture Region", action: #selector(captureMenu), keyEquivalent: "4")
        capItem.keyEquivalentModifierMask = [.command, .shift]
        capItem.target = self
        menu.addItem(capItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About ScreenGrabber", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = [.command]
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenGrabber",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// A template menu-bar glyph mirroring the app icon: the selection-region
    /// brackets with an annotation arrow inside. Template = adapts to light/dark.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let S = rect.width, u = S / 18.0
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Selection brackets.
            let inset: CGFloat = 1.4 * u
            let r = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
            let arm: CGFloat = 4.6 * u
            ctx.setLineWidth(1.7 * u)
            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: r.minX + arm, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - arm)),
                (CGPoint(x: r.maxX - arm, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY - arm)),
                (CGPoint(x: r.minX + arm, y: r.minY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.minY + arm)),
                (CGPoint(x: r.maxX - arm, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + arm)),
            ]
            for (a, c, b) in corners { ctx.move(to: a); ctx.addLine(to: c); ctx.addLine(to: b); ctx.strokePath() }

            // Annotation arrow.
            let tail = CGPoint(x: 6.0 * u, y: 6.0 * u), tip = CGPoint(x: 12.0 * u, y: 12.0 * u)
            let dx = tip.x - tail.x, dy = tip.y - tail.y
            let len = (dx * dx + dy * dy).squareRoot()
            let ux = dx / len, uy = dy / len, px = -uy, py = ux
            let headLen: CGFloat = 5.0 * u, headHalf: CGFloat = 3.3 * u
            let neck = CGPoint(x: tip.x - ux * headLen, y: tip.y - uy * headLen)
            ctx.setLineWidth(1.9 * u)
            ctx.move(to: tail); ctx.addLine(to: CGPoint(x: neck.x + ux * 0.4 * u, y: neck.y + uy * 0.4 * u)); ctx.strokePath()
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: neck.x + px * headHalf, y: neck.y + py * headHalf))
            ctx.addLine(to: CGPoint(x: neck.x - px * headHalf, y: neck.y - py * headHalf))
            ctx.closePath(); ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ScreenGrabber"
        return image
    }

    @objc private func captureMenu() { beginCapture() }

    private func beginCapture() {
        // screencapture owns the screen during selection; ignore re-triggers.
        guard !capturing else { return }
        capturing = true
        capture.beginCapture { [weak self] image in
            guard let self = self else { return }
            self.capturing = false
            guard let image = image else { return }

            // Auto-save: write the raw capture immediately (so a file exists right
            // away, like the system shortcut); the editor updates it on close.
            var autoSaveURL: URL?
            if Preferences.shared.autoSave {
                let url = Preferences.shared.makeFileURL()
                writePNG(image, to: url)
                autoSaveURL = url
            }
            self.openEditor(with: image, autoSaveURL: autoSaveURL)
        }
    }

    private func openEditor(with image: CGImage, autoSaveURL: URL?) {
        let controller = EditorWindowController(image: image, autoSaveURL: autoSaveURL,
                                                onOpenPreferences: { [weak self] in self?.showPreferences() })
        controller.onClose = { [weak self, weak controller] in
            self?.editors.removeAll { $0 === controller }
            self?.updateActivationPolicy()
        }
        editors.append(controller)
        // Become a regular app while editing so the window shows in the Dock and
        // Cmd-Tab switcher; we drop back to accessory once all editors close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Stay in the Dock / Cmd-Tab only while at least one editor is open.
    private func updateActivationPolicy() {
        NSApp.setActivationPolicy(editors.isEmpty ? .accessory : .regular)
    }

    // MARK: - Menu actions

    @objc private func showPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)

        let credits = NSMutableAttributedString(
            string: "A fast capture-and-annotate screenshot tool for macOS.\n\n")
        let link = NSMutableAttributedString(string: repoURL.replacingOccurrences(of: "https://", with: ""))
        link.addAttribute(.link, value: repoURL, range: NSRange(location: 0, length: link.length))
        credits.append(link)
        credits.addAttributes([.font: NSFont.systemFont(ofSize: 11)],
                              range: NSRange(location: 0, length: credits.length))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para,
                             range: NSRange(location: 0, length: credits.length))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ScreenGrabber",
            .credits: credits,
        ])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: lives in the menu bar, no Dock icon, doesn't steal focus until we
// explicitly activate to show an editor.
app.setActivationPolicy(.accessory)
app.run()
