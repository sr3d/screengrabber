import AppKit

/// A transient, non-interactive "toast" shown near the bottom-center of the
/// screen to confirm an action (e.g. copy-on-capture) without stealing focus.
/// Reuses a single window; repeated calls replace the current message.
enum Toast {
    private static var window: NSWindow?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, duration: TimeInterval = 2.2) {
        DispatchQueue.main.async { present(message, duration: duration) }
    }

    private static func present(_ message: String, duration: TimeInterval) {
        hideWork?.cancel()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        bg.layer?.cornerRadius = 12
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -11),
        ])
        bg.layoutSubtreeIfNeeded()
        let size = bg.fittingSize

        let win = window ?? makeWindow()
        window = win
        win.setContentSize(size)
        win.contentView = bg

        // Position on the display under the cursor (where the capture happened).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            win.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 120))
        }

        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            win.animator().alphaValue = 1
        }

        let work = DispatchWorkItem(block: dismiss)
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func dismiss() {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            win.animator().alphaValue = 0
        }, completionHandler: { win.orderOut(nil) })
    }

    private static func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.ignoresMouseEvents = true
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return win
    }
}
