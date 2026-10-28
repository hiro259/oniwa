import AppKit
import Carbon.HIToolbox

/// System shortcut conflicts do not always cause RegisterEventHotKey to fail.
/// An observable receive counter and user-selectable presets make this debuggable.
final class GlobalShortcut {
    enum Preset: String, CaseIterable {
        case controlOptionShiftO
        case controlOptionShiftSpace
        case controlCommandO

        var title: String {
            switch self {
            case .controlOptionShiftO: return "⌃⌥⇧ O"
            case .controlOptionShiftSpace: return "⌃⌥⇧ Space"
            case .controlCommandO: return "⌃⌘ O (旧設定)"
            }
        }

        var keyCode: UInt32 {
            switch self {
            case .controlOptionShiftO, .controlCommandO:
                return UInt32(kVK_ANSI_O)
            case .controlOptionShiftSpace:
                return UInt32(kVK_Space)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .controlOptionShiftO, .controlOptionShiftSpace:
                return UInt32(controlKey | optionKey | shiftKey)
            case .controlCommandO:
                return UInt32(controlKey | cmdKey)
            }
        }
    }

    private static let preferenceKey = "oniwa.hotkeyPreset.v1"
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var onPress: (() -> Void)?
    private(set) var registrationError: String?
    private(set) var receivedCount = 0
    private(set) var lastReceivedAt: Date?
    private(set) var preset: Preset = .controlOptionShiftO

    var isRegistered: Bool { hotKey != nil }

    private static let handler: EventHandlerUPP = { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            owner.receivedCount += 1
            owner.lastReceivedAt = Date()
            NSLog("ONIWA: hotkey event received (count=%d)", owner.receivedCount)
            owner.onPress?()
        }
        return noErr
    }

    init() {
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(),
                                            Self.handler, 1, &kind, opaque, &eventHandler)
        guard installed == noErr else {
            registrationError = "Event handler installation failed (code \(installed))."
            NSLog("ONIWA: %@", registrationError!)
            return
        }
        let preferred = Preset(rawValue: UserDefaults.standard.string(forKey: Self.preferenceKey) ?? "")
            ?? .controlOptionShiftO
        if !register(preferred) && preferred != .controlOptionShiftO {
            _ = register(.controlOptionShiftO)
        }
    }

    /// Claim the new shortcut before releasing the old one. Failed changes
    /// leave the previous working shortcut intact.
    @discardableResult
    func register(_ choice: Preset) -> Bool {
        guard eventHandler != nil else {
            registrationError = "Keyboard event handler is unavailable."
            return false
        }
        if preset == choice && hotKey != nil { return true }

        var candidate: EventHotKeyRef?
        let identifier = UInt32(hotKey == nil ? 1 : 2)
        let id = EventHotKeyID(signature: 0x4F4E4957, id: identifier) // ONIW
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, id,
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else {
            registrationError = "\(choice.title): registration failed (code \(status))."
            NSLog("ONIWA: %@", registrationError!)
            return false
        }
        let previous = hotKey
        hotKey = candidate
        preset = choice
        registrationError = nil
        UserDefaults.standard.set(choice.rawValue, forKey: Self.preferenceKey)
        if let previous {
            let release = UnregisterEventHotKey(previous)
            if release != noErr {
                NSLog("ONIWA: warning: previous shortcut release failed (%d)", release)
            }
        }
        NSLog("ONIWA: registered shortcut %@. Registration alone does not prove events are delivered.", choice.title)
        return true
    }

    func diagnosticSummary() -> String {
        let last = lastReceivedAt.map { DateFormatter.localizedString(
            from: $0, dateStyle: .none, timeStyle: .medium) } ?? "なし"
        let registration = isRegistered ? "登録APIは成功" : "登録できていません"
        let extra = registrationError.map { "\nエラー: \($0)" } ?? ""
        return """
        設定: \(preset.title)
        状態: \(registration)
        この起動中の受信回数: \(receivedCount)
        最終受信時刻: \(last)\(extra)

        受信回数が増えない場合は、他のアプリやmacOSのショートカットとの競合、またはキーイベントの配送失敗が考えられます。「ショートカット」メニューで別の組み合わせを試してください。
        """
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
