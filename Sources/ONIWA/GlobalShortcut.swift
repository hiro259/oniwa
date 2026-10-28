import AppKit
import Carbon.HIToolbox

/// Global Ctrl+Option+Space. An additional menu-bar entry remains available if
/// another application claims the shortcut.
final class GlobalShortcut {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var onPress: (() -> Void)?

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
        guard installed == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: 0x4F4E4957, id: 1) // ONIW
        let registered = RegisterEventHotKey(UInt32(kVK_Space),
                                               UInt32(controlKey | optionKey),
                                               hotKeyID, GetApplicationEventTarget(),
                                               0, &hotKey)
        if registered != noErr { NSLog("ONIWA: global shortcut unavailable: %d", registered) }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
