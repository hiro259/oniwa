/// macOS "Switch to Desktop N" shortcuts address *Desktop* Spaces only.
/// SkyLight's managed-space array also contains fullscreen Spaces; those
/// occupy positions but must not be counted as numbered Desktops.
public enum DesktopNumberShortcutPolicy {
    public enum Plan: Equatable {
        case direct(number: Int, keyCode: UInt16)
        case fallback(reason: String)
    }

    private static let keyCodes: [UInt16] = [
        18, 19, 20, 21, 23, 22, 26, 28, 25
    ]

    public static func plan(kinds: [Int], targetIndex: Int) -> Plan {
        guard kinds.indices.contains(targetIndex) else {
            return .fallback(reason: "target-index-out-of-range")
        }
        guard kinds[targetIndex] == 0 else {
            return .fallback(reason: "not-a-desktop")
        }
        let ordinal = kinds[...targetIndex].filter { $0 == 0 }.count
        guard (1...9).contains(ordinal) else {
            return .fallback(reason: "desktop-number-outside-1-9")
        }
        return .direct(number: ordinal, keyCode: keyCodes[ordinal - 1])
    }
}
