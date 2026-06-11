import AppKit

/// User settings, persisted in `UserDefaults`. Defaults mirror macOS's own
/// screenshot behavior (Desktop location, "Screenshot …" filename).
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let saveDirPath = "saveDirectoryPath"
        static let prefix = "filenamePrefix"
        static let autoSave = "autoSaveOnCapture"
    }

    private init() {}

    // MARK: - Auto-save

    var autoSave: Bool {
        get { defaults.object(forKey: Key.autoSave) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoSave) }
    }

    // MARK: - Save location

    /// A user-chosen directory path, or nil to follow the macOS default.
    var saveDirectoryPath: String? {
        get { defaults.string(forKey: Key.saveDirPath) }
        set { defaults.set(newValue, forKey: Key.saveDirPath) }
    }

    var usingDefaultDirectory: Bool { (saveDirectoryPath ?? "").isEmpty }

    var saveDirectory: URL {
        if let p = saveDirectoryPath, !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Self.systemDefaultDirectory
    }

    /// macOS stores the screenshot folder in `com.apple.screencapture` → `location`;
    /// otherwise it's the Desktop.
    static var systemDefaultDirectory: URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    // MARK: - Filename

    var filenamePrefix: String {
        get {
            let p = defaults.string(forKey: Key.prefix)
            return (p?.isEmpty == false) ? p! : Self.systemDefaultPrefix
        }
        set { defaults.set(newValue, forKey: Key.prefix) }
    }

    /// macOS stores the prefix in `com.apple.screencapture` → `name` (default "Screenshot").
    static var systemDefaultPrefix: String {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "name") ?? "Screenshot"
    }

    private func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return fmt.string(from: Date())
    }

    /// e.g. "Screenshot 2026-06-10 at 3.45.12 PM.png" (no uniquing — for previews).
    func previewFilename() -> String { "\(filenamePrefix) \(timestamp()).png" }

    /// A unique destination URL in the save directory, matching macOS's naming.
    func makeFileURL() -> URL {
        let dir = saveDirectory
        let base = "\(filenamePrefix) \(timestamp())"
        var url = dir.appendingPathComponent(base).appendingPathExtension("png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("png")
            n += 1
        }
        return url
    }
}

/// Writes a CGImage to disk as PNG, creating the parent directory if needed.
@discardableResult
func writePNG(_ image: CGImage, to url: URL) -> Bool {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try data.write(to: url)
        return true
    } catch {
        NSLog("ScreenGrabber: failed to save \(url.path): \(error)")
        return false
    }
}
