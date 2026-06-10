import AppKit
import Carbon

/// Registers global hot keys via the Carbon Event Manager. This works without
/// Accessibility permissions (unlike NSEvent global monitors), which keeps the
/// app friction-free to install.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    /// keyCode is a virtual key code (e.g. `kVK_ANSI_4`); modifiers is a Carbon
    /// modifier mask (e.g. `cmdKey | shiftKey`).
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x53475242 /* 'SGRB' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            refs[id] = ref
        } else {
            NSLog("ScreenGrabber: failed to register hot key (status \(status)). " +
                  "Another app or the system may already own this shortcut.")
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // The callback captures nothing, so it converts to a C function pointer.
        // It dispatches through the shared singleton by hot-key id.
        let callback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let handler = HotKeyCenter.shared.handlers[hkID.id] {
                DispatchQueue.main.async(execute: handler)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, nil)
    }
}
