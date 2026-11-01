import AppKit
import CoreGraphics
import Foundation
import ONIWACore

/// Sends the existing macOS Control+digit *system* shortcut. This is not a
/// SkyLight setter and it never opens Mission Control. The shortcut must
/// already be enabled by the user in Keyboard > Keyboard Shortcuts.
///
/// Only type-0 Desktop Spaces with a proven 1...9 ordinal are eligible.
/// If the configured shortcut differs from standard Control+digit, the
/// experiment uses the existing verified arrow-key route instead.
enum DesktopNumberShortcut {
    struct Ready {
        let number: Int
        let keyCode: CGKeyCode
    }

    enum Preparation {
        case ready(Ready)
        case fallback(String)
    }

    static func prepare(_ space: SpaceEntry, in display: DisplayGroup) -> Preparation {
        guard let index = display.spaces.firstIndex(where: {
            $0.identity == space.identity
        }) else { return .fallback("target-identity-not-in-display") }
        let kinds = display.spaces.map(\.kind)
        switch DesktopNumberShortcutPolicy.plan(kinds: kinds, targetIndex: index) {
        case .fallback(let reason):
            return .fallback(reason)
        case .direct(let number, let code):
            guard standardShortcutEnabled(number: number, expectedKeyCode: Int(code)) else {
                return .fallback("ctrl-digit-disabled-or-customized-\(number)")
            }
            return .ready(Ready(number: number, keyCode: CGKeyCode(code)))
        }
    }

    /// Action IDs 118...126 are the system "Switch to Desktop 1...9"
    /// symbolic shortcuts. Never enable them or modify user preferences.
    private static func standardShortcutEnabled(number: Int, expectedKeyCode: Int) -> Bool {
        guard (1...9).contains(number),
              let domain = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let values = domain.dictionary(forKey: "AppleSymbolicHotKeys"),
              let record = values[String(117 + number)] as? [String: Any],
              (record["enabled"] as? Bool) == true,
              let value = record["value"] as? [String: Any],
              let params = value["parameters"] as? [NSNumber],
              params.count >= 3 else { return false }

        // Default Ctrl+1..9 is 0x00040000 in Carbon shortcut flags.
        // Custom shortcuts must never be mistaken for Ctrl+digit.
        return params[1].intValue == expectedKeyCode
            && params[2].intValue == 0x00040000
    }

    static func post(_ shortcut: Ready) -> Bool {
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            return false
        }
        let controlCode: CGKeyCode = 59
        guard let source = CGEventSource(stateID: .hidSystemState),
              let controlDown = CGEvent(keyboardEventSource: source,
                                        virtualKey: controlCode, keyDown: true),
              let digitDown = CGEvent(keyboardEventSource: source,
                                      virtualKey: shortcut.keyCode, keyDown: true),
              let digitUp = CGEvent(keyboardEventSource: source,
                                    virtualKey: shortcut.keyCode, keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: source,
                                      virtualKey: controlCode, keyDown: false) else {
            return false
        }
        controlDown.flags = .maskControl
        digitDown.flags = .maskControl
        digitUp.flags = .maskControl
        controlUp.flags = []
        controlDown.post(tap: .cghidEventTap)
        digitDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        digitUp.post(tap: .cghidEventTap)
        controlUp.post(tap: .cghidEventTap)
        // Posting returns no OS delivery/transition acknowledgement.
        return true
    }
}
