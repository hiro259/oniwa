import AppKit
import Carbon.HIToolbox

/// A physical key and its Carbon modifier bits. The human-readable key name is
/// stored separately so a custom shortcut stays understandable after relaunch.
struct HotKeyCombination: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    var title: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + " " + keyName
    }

    static func capture(_ event: NSEvent) -> HotKeyCombination? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        // Global shortcuts without a strong modifier interfere with normal typing.
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        let keyCode = UInt32(event.keyCode)
        guard keyCode != UInt32(kVK_Escape),
              keyCode != UInt32(kVK_Return),
              keyCode != UInt32(kVK_Tab),
              keyCode != UInt32(kVK_Delete) else { return nil }

        let name: String
        switch keyCode {
        case UInt32(kVK_Space): name = "Space"
        case UInt32(kVK_UpArrow): name = "↑"
        case UInt32(kVK_DownArrow): name = "↓"
        case UInt32(kVK_LeftArrow): name = "←"
        case UInt32(kVK_RightArrow): name = "→"
        default:
            let candidate = event.charactersIgnoringModifiers?.uppercased() ?? ""
            guard !candidate.isEmpty,
                  !candidate.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            name = String(candidate.prefix(4))
        }
        return HotKeyCombination(keyCode: keyCode, modifiers: modifiers, keyName: name)
    }
}

/// Carbon hotkey registration is intentionally independent of Accessibility
/// permission. Successful registration does NOT prove macOS delivers the event.
final class GlobalShortcut {
    enum Preset: String, CaseIterable {
        case optionSpace
        case controlOptionShiftO
        case controlOptionShiftSpace
        case controlCommandO

        var combination: HotKeyCombination {
            switch self {
            case .optionSpace:
                return .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyName: "Space")
            case .controlOptionShiftO:
                return .init(keyCode: UInt32(kVK_ANSI_O),
                             modifiers: UInt32(controlKey | optionKey | shiftKey), keyName: "O")
            case .controlOptionShiftSpace:
                return .init(keyCode: UInt32(kVK_Space),
                             modifiers: UInt32(controlKey | optionKey | shiftKey), keyName: "Space")
            case .controlCommandO:
                return .init(keyCode: UInt32(kVK_ANSI_O),
                             modifiers: UInt32(controlKey | cmdKey), keyName: "O")
            }
        }

        var title: String { combination.title }
    }

    private static let customKey = "oniwa.hotkeyCombination.v2"
    private static let legacyKey = "oniwa.hotkeyPreset.v1"
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var activeIdentifier: UInt32 = 0

    var onPress: (() -> Void)?
    private(set) var registrationError: String?
    private(set) var receivedCount = 0
    private(set) var lastReceivedAt: Date?
    private(set) var current: HotKeyCombination = Preset.optionSpace.combination

    var isRegistered: Bool { hotKey != nil }

    private static let handler: EventHandlerUPP = { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            owner.receivedCount += 1
            owner.lastReceivedAt = Date()
            NSLog("ONIWA: hotkey received (count=%d)", owner.receivedCount)
            owner.onPress?()
        }
        return noErr
    }

    init() {
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         Self.handler, 1, &kind, opaque, &eventHandler)
        guard status == noErr else {
            registrationError = "Event handler installation failed (code \(status))."
            return
        }
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: Self.customKey)
            .flatMap { try? JSONDecoder().decode(HotKeyCombination.self, from: $0) }
        let legacy = defaults.string(forKey: Self.legacyKey)
            .flatMap { Preset(rawValue: $0)?.combination }
        let preferred = saved ?? legacy ?? Preset.optionSpace.combination
        if !register(preferred), preferred != Preset.controlOptionShiftO.combination {
            let reason = registrationError
            if register(Preset.controlOptionShiftO.combination) {
                registrationError = "Preferred shortcut was unavailable (\(reason ?? "unknown")). Using ⌃⌥⇧ O instead."
            }
        }
    }

    /// Attempt the new key before releasing the existing registration. On failure
    /// the original remains active, even when macOS refuses the new combination.
    @discardableResult
    func register(_ combination: HotKeyCombination) -> Bool {
        guard eventHandler != nil else {
            registrationError = "Keyboard event handler is unavailable."
            return false
        }
        if hotKey != nil && current.keyCode == combination.keyCode
            && current.modifiers == combination.modifiers { return true }
        var candidate: EventHotKeyRef?
        let identifier: UInt32 = activeIdentifier == 1 ? 2 : 1
        let id = EventHotKeyID(signature: 0x4F4E4957, id: identifier) // ONIW
        let status = RegisterEventHotKey(combination.keyCode, combination.modifiers,
                                         id, GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else {
            registrationError = "\(combination.title) could not be registered (code \(status))."
            NSLog("ONIWA: %@", registrationError!)
            return false
        }
        let previous = hotKey
        hotKey = candidate
        activeIdentifier = identifier
        current = combination
        registrationError = nil
        if let data = try? JSONEncoder().encode(combination) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
        if let previous {
            let result = UnregisterEventHotKey(previous)
            if result != noErr { NSLog("ONIWA: old hotkey release failed: %d", result) }
        }
        NSLog("ONIWA: registered %@; actual delivery must be tested.", combination.title)
        return true
    }

    /// Temporarily release the current shortcut so it does not steal the same
    /// combination while the recording window has keyboard focus.
    func beginRecording() -> Bool {
        guard let existing = hotKey else { return true }
        let status = UnregisterEventHotKey(existing)
        guard status == noErr else {
            registrationError = "Could not pause the current shortcut (code \(status))."
            return false
        }
        hotKey = nil
        return true
    }

    /// A cancelled recording re-enables the previous key. A failed new
    /// registration also restores it, preserving the known-working setting.
    @discardableResult
    func endRecording(_ candidate: HotKeyCombination?) -> Bool {
        let old = current
        guard let candidate else { return register(old) }
        if register(candidate) { return true }
        let failedReason = registrationError
        let restored = register(old)
        registrationError = restored ? failedReason : "Shortcut failed and previous shortcut could not be restored."
        return false
    }

    func diagnosticSummary() -> String {
        let last = lastReceivedAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium)
        } ?? "なし"
        let status = isRegistered ? "登録APIは成功" : "登録できていません"
        let extra = registrationError.map { "\n注意: \($0)" } ?? ""
        return """
        設定: \(current.title)
        状態: \(status)
        この起動中の受信回数: \(receivedCount)
        最終受信時刻: \(last)\(extra)

        登録成功でもキー入力が届かない場合があります。ほかのショートカットを記録して試してください。
        """
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
