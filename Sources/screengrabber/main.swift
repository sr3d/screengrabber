import AppKit
import Carbon
import ImageIO
import Sparkle
import UniformTypeIdentifiers

private let repoURL = "https://github.com/sr3d/screengrabber"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUUpdaterDelegate {
    private var statusItem: NSStatusItem!
    private let recentMenu = NSMenu(title: "Recent Screenshots")
    private var thumbnailCache: [String: NSImage] = [:]
    private let capture = CaptureController()
    private var editors: [EditorWindowController] = []
    private var capturing = false
    private var preferencesController: PreferencesWindowController?

    /// Sparkle auto-updater. `startingUpdater: true` kicks off the background
    /// check schedule; it reads the feed (SUFeedURL) and verifies downloads with
    /// the EdDSA public key (SUPublicEDKey), both in Info.plist. Lazy so we can
    /// pass `self` as the delegate (for error diagnostics).
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    /// The system ⇧⌘4 shortcut's enabled-state before we took it over, so we can
    /// hand it back on a clean quit.
    private var systemShortcutWasEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // Take ⇧⌘4 from the system so our Carbon hot key wins. macOS's
        // WindowServer fires the built-in screenshot shortcut before Carbon hot
        // keys are dispatched, so we must disable the system shortcut first —
        // otherwise it pre-empts us and `screencapture` runs instead.
        systemShortcutWasEnabled = SystemShortcuts.isEnabled(SystemShortcuts.saveSelectedAreaToFile)
        if SystemShortcuts.isAvailable {
            SystemShortcuts.setEnabled(SystemShortcuts.saveSelectedAreaToFile, false)
        } else {
            NSLog("ScreenGrabber: can't toggle the system ⇧⌘4 shortcut on this macOS; " +
                  "disable it manually in System Settings ▸ Keyboard ▸ Shortcuts ▸ Screenshots.")
        }

        // ⇧⌘4 — kVK_ANSI_4 is 0x15.
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_4),
                                     modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.beginCapture()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Be polite: when ScreenGrabber isn't running, give ⇧⌘4 back to macOS
        // if that's how we found it.
        if systemShortcutWasEnabled {
            SystemShortcuts.setEnabled(SystemShortcuts.saveSelectedAreaToFile, true)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let capItem = NSMenuItem(title: "Capture Region", action: #selector(captureMenu), keyEquivalent: "4")
        capItem.keyEquivalentModifierMask = [.command, .shift]
        capItem.target = self
        menu.addItem(capItem)

        let openItem = NSMenuItem(title: "Open Image…", action: #selector(openImage), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        menu.addItem(openItem)

        // Recent screenshots — populated lazily when the submenu opens.
        recentMenu.delegate = self
        let recentItem = NSMenuItem(title: "Recent Screenshots", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About ScreenGrabber", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Sparkle's standard controller handles the action and enables/disables
        // the item automatically (e.g. while a check is already in progress).
        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = updaterController
        menu.addItem(updatesItem)

        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = [.command]
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenGrabber",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Overlay the button with a drop view so image files dragged onto the
        // menu-bar icon open in the editor. The overlay also pops `menu` on click
        // (covering the button suppresses its built-in menu), so we don't set
        // `statusItem.menu`.
        if let button = statusItem.button {
            button.image = AppDelegate.menuBarIcon()
            let drop = MenuBarDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.statusItem = statusItem
            drop.statusMenu = menu
            drop.onDropImages = { [weak self] urls in self?.openImages(at: urls) }
            button.addSubview(drop)
        }
    }

    /// Picks image files and opens each in an editor. Handy for working on an
    /// existing image — and for exercising the editor without taking a fresh
    /// capture, which an ad-hoc-signed rebuild would re-prompt for.
    @objc private func openImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.message = "Choose an image to open in the editor"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openImages(at: panel.urls)
        }
    }

    /// Opens each dropped image file in its own editor window. No auto-save URL —
    /// edits won't overwrite the user's original file (use Save… / Copy File).
    private func openImages(at urls: [URL]) {
        var opened = 0
        for url in urls {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            openEditor(with: cg, autoSaveURL: nil)
            Preferences.shared.addRecentFile(url)
            opened += 1
        }
        if opened == 0 { Toast.show("Couldn't open that image") }
    }

    // MARK: - Recent screenshots

    /// Rebuilds the recents submenu just before it opens, so it always reflects
    /// the latest files (and drops any that were deleted).
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()

        let urls = Preferences.shared.recentFileURLs()
        guard !urls.isEmpty else {
            let empty = NSMenuItem(title: "No recent screenshots", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = thumbnail(for: url)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openImages(at: [url])
    }

    @objc private func clearRecents() {
        Preferences.shared.clearRecentFiles()
    }

    // MARK: - Update diagnostics (SPUUpdaterDelegate)

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Returning nil keeps the Info.plist SUFeedURL; we read it here only to
        // include it in error diagnostics.
        nil
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        // A plain user cancel isn't worth reporting.
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return }

        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "(none)"
        let detail = "Feed: \(feed)\n\n" + AppDelegate.describe(error)
        NSLog("ScreenGrabber update error:\n\(detail)")

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Details")
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(detail, forType: .string)
            }
        }
    }

    /// Flattens an NSError chain (domain, code, message, failing URL, underlying
    /// errors) into a readable multi-line string for debugging.
    private static func describe(_ error: Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current {
            let indent = String(repeating: "    ", count: depth)
            lines.append("\(indent)• \(e.domain) (code \(e.code))")
            lines.append("\(indent)  \(e.localizedDescription)")
            if let reason = e.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
                lines.append("\(indent)  reason: \(reason)")
            }
            if let url = e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                lines.append("\(indent)  url: \(url)")
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return lines.joined(separator: "\n")
    }

    /// A small thumbnail for a menu row, cached by path + modification time so an
    /// edited screenshot (re-saved to the same path) refreshes.
    private func thumbnail(for url: URL) -> NSImage? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(mtime)"
        if let cached = thumbnailCache[key] { return cached }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }

        // Display ~24pt tall (the 48px source stays crisp on Retina).
        let targetH: CGFloat = 24
        let s = targetH / CGFloat(cg.height)
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) * s, height: targetH))
        thumbnailCache[key] = img
        return img
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
            let prefs = Preferences.shared

            // Copy straight to the clipboard so a quick capture is paste-ready.
            if prefs.copyToClipboardOnCapture {
                copyImageToClipboard(image)
                Toast.show("Screenshot copied to clipboard")
            }

            // Auto-save: write the raw capture immediately (so a file exists right
            // away, like the system shortcut); the editor updates it on close.
            var autoSaveURL: URL?
            if prefs.autoSave {
                let url = prefs.makeFileURL()
                writePNG(image, to: url)
                autoSaveURL = url
                prefs.addRecentFile(url)
            }

            if prefs.showEditorOnCapture {
                self.openEditor(with: image, autoSaveURL: autoSaveURL)
            } else if !prefs.copyToClipboardOnCapture, autoSaveURL != nil {
                // No editor and no copy toast yet — confirm the save instead.
                Toast.show("Screenshot saved")
            }
        }
    }

    private func openEditor(with image: CGImage, autoSaveURL: URL?) {
        let controller = EditorWindowController(image: image, autoSaveURL: autoSaveURL,
                                                onOpenPreferences: { [weak self] in self?.showPreferences() },
                                                onOpenImage: { [weak self] in self?.openImage() })
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
            preferencesController = PreferencesWindowController(updater: updaterController.updater)
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
