import Foundation

/// Toggles macOS's built-in screenshot keyboard shortcuts so our ⇧⌘4 hot key
/// isn't pre-empted by the system.
///
/// macOS routes the screenshot shortcuts through the WindowServer, which fires
/// *before* Carbon hot keys are dispatched. So even when `RegisterEventHotKey`
/// succeeds, the system's `screencapture` runs instead of our handler as long as
/// the matching system shortcut is enabled. Disabling it hands the key combo to
/// our Carbon hot key.
///
/// The toggle lives in the private SkyLight API `CGSSetSymbolicHotKeyEnabled`.
/// We resolve it at runtime with `dlsym` so a future macOS that drops the symbol
/// degrades to a no-op (falling back to the manual System Settings step) rather
/// than failing to launch. No Accessibility permission is required.
enum SystemShortcuts {
    /// Symbolic hot-key IDs from `com.apple.symbolichotkeys`.
    /// 30 = "Save picture of selected area as a file" (⇧⌘4).
    static let saveSelectedAreaToFile: Int32 = 30

    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabledFn = @convention(c) (Int32) -> Bool

    private static let setEnabledFn: SetEnabledFn? = symbol("CGSSetSymbolicHotKeyEnabled")
    private static let isEnabledFn: IsEnabledFn? = symbol("CGSIsSymbolicHotKeyEnabled")

    /// `dlsym` with `RTLD_DEFAULT` (-2) searches every loaded image; the SkyLight
    /// symbols are already in-process via AppKit.
    private static func symbol<T>(_ name: String) -> T? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// Whether the private API is available on this OS.
    static var isAvailable: Bool { setEnabledFn != nil }

    static func isEnabled(_ id: Int32) -> Bool {
        isEnabledFn?(id) ?? false
    }

    /// Returns true on success (`kCGErrorSuccess`).
    @discardableResult
    static func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool {
        guard let setEnabledFn = setEnabledFn else { return false }
        return setEnabledFn(id, enabled) == 0
    }
}
