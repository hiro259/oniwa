import AppKit
import Carbon.HIToolbox

/// Global Control+Command+O. Avoid Ctrl+Option+Space, reserved for macOS
/// input-source switching. The menu bar remains available as a fallback.
final class GlobalShortcut {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var onPress: (() -> Void)?
    private(set) var registrationError: String?

    private static let handler: EventHandlerUPP = { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { owner.onPress?() }
        return noErr
    }

    init() {
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(),
                                            Self.handler, 1, &kind, opaque, &eventHandler)
        guard installed == noErr else {
            registrationError = "Could not install the keyboard event handler (\(installed))."
            NSLog("ONIWA: %@", registrationError!)
            return
        }
        let hotKeyID = EventHotKeyID(signature: 0x4F4E4957, id: 1) // ONIW
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_O),
                                               UInt32(controlKey | cmdKey),
                                               hotKeyID, GetApplicationEventTarget(),
                                               0, &hotKey)
        if registered != noErr {
            registrationError = "⌃⌘O is unavailable (code \(registered)). Try the menu bar instead."
            NSLog("ONIWA: %@", registrationError!)
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
