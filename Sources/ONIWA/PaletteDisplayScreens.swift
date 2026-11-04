import AppKit
import CoreGraphics
import ONIWACore

/// Screen identities are resolved afresh on every palette open. Numeric
/// CGDirectDisplayIDs and NSScreen array positions may change on reconnect.
@MainActor
enum PaletteDisplayScreens {
    struct Connected {
        let screen: NSScreen
        let uuid: String
        let name: String
        let isBuiltIn: Bool
    }

    static func connected() -> [Connected] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            else { return nil }
            let uuidString = CFUUIDCreateString(nil, rawUUID) as String
            guard let uuid = UUID(uuidString: uuidString) else { return nil }
            return Connected(
                screen: screen,
                uuid: uuid.uuidString,
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
            )
        }
    }

    static func resolve(_ preference: PaletteDisplaySelection) -> NSScreen? {
        let displays = connected()
        let selected = preference.resolvedDisplayUUID(
            availableUUIDs: displays.map(\.uuid),
            builtInUUID: displays.first(where: \.isBuiltIn)?.uuid,
            primaryUUID: displays.first?.uuid
        )
        return displays.first(where: { $0.uuid == selected })?.screen ?? NSScreen.screens.first
    }
}
