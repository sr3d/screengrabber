import AppKit

/// Drives the native `screencapture` tool to do an interactive region selection
/// (the same crosshair drag as the system ⇧⌘4), then hands back a full-resolution
/// CGImage. Reusing the system selector means we don't reinvent the drag UI and
/// the Screen Recording permission prompt is presented natively on first use.
final class CaptureController {

    /// Presents the crosshair selector. `completion` is called on the main queue
    /// with the captured image, or `nil` if the user pressed Escape / cancelled.
    func beginCapture(completion: @escaping (CGImage?) -> Void) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sg-\(ProcessInfo.processInfo.globallyUniqueString).png")

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: interactive region select. -o: no window shadow (region mode ignores it).
            proc.arguments = ["-i", "-o", path]
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // No file means the user cancelled the selection.
            guard let data = FileManager.default.contents(atPath: path) as CFData?,
                  let source = CGImageSourceCreateWithData(data, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            try? FileManager.default.removeItem(atPath: path)
            DispatchQueue.main.async { completion(image) }
        }
    }
}
