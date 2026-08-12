import AppKit
import UniformTypeIdentifiers

/// A transparent overlay sized to the status-bar button. It does two things the
/// bare `NSStatusItem.button` can't do together:
///
///  1. Accepts image files dragged onto the menu-bar icon (opens them in the
///     editor).
///  2. Forwards clicks to pop the status menu — because covering the button to
///     receive drags suppresses its built-in click-to-open-menu behavior, we
///     show the menu ourselves.
final class MenuBarDropView: NSView {

    var onDropImages: (([URL]) -> Void)?
    weak var statusItem: NSStatusItem?
    var statusMenu: NSMenu?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Clicks → menu

    override func mouseDown(with event: NSEvent) { popMenu() }
    override func rightMouseDown(with event: NSEvent) { popMenu() }

    private func popMenu() {
        guard let menu = statusMenu, let button = statusItem?.button else { return }
        button.highlight(true)
        // popUp blocks until the menu is dismissed, so we can un-highlight after.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        button.highlight(false)
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropImages?(urls)
        return true
    }

    /// File URLs on the drag pasteboard whose contents are image files.
    private func imageURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }
}
