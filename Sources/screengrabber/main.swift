import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let capture = CaptureController()
    private var editors: [EditorWindowController] = []
    private var capturing = false

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
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "ScreenGrabber")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let item = NSMenuItem(title: "Capture Region", action: #selector(captureMenu), keyEquivalent: "4")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        menu.addItem(item)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenGrabber",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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
            self.openEditor(with: image)
        }
    }

    private func openEditor(with image: CGImage) {
        let controller = EditorWindowController(image: image)
        controller.onClose = { [weak self, weak controller] in
            self?.editors.removeAll { $0 === controller }
        }
        editors.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: lives in the menu bar, no Dock icon, doesn't steal focus until we
// explicitly activate to show an editor.
app.setActivationPolicy(.accessory)
app.run()
