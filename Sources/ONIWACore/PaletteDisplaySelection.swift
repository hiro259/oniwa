import Foundation

/// A display preference independent of macOS's transient CGDirectDisplayID.
///
/// The menu uses a built-in display option (or primary display on desktop Macs)
/// and individually identified external displays. An unavailable selection is
/// retained: it temporarily falls back instead of silently adopting a new ID.
public struct PaletteDisplaySelection: Equatable {
    public static let settingsKey = "oniwa.paletteDisplaySelection"
    public static let builtInValue = "built-in"
    private static let displayPrefix = "display:"

    /// Nil means the built-in display preference.
    public let preferredDisplayUUID: String?

    public init(storedValue: String?) {
        guard let storedValue,
              storedValue.hasPrefix(Self.displayPrefix),
              let identifier = UUID(uuidString: String(storedValue.dropFirst(Self.displayPrefix.count)))
        else {
            preferredDisplayUUID = nil
            return
        }
        preferredDisplayUUID = identifier.uuidString
    }

    public init(displayUUID: String) {
        preferredDisplayUUID = UUID(uuidString: displayUUID)?.uuidString
    }

    public var storedValue: String {
        preferredDisplayUUID.map { Self.displayPrefix + $0 } ?? Self.builtInValue
    }

    /// Choose the persisted display when connected; otherwise fall back to the
    /// built-in screen and finally the current primary screen. No guessing from
    /// display names, array positions, or a reused numerical display ID.
    public func resolvedDisplayUUID(
        availableUUIDs: [String],
        builtInUUID: String?,
        primaryUUID: String?
    ) -> String? {
        let available = Set(availableUUIDs)
        if let preferredDisplayUUID, available.contains(preferredDisplayUUID) {
            return preferredDisplayUUID
        }
        if let builtInUUID, available.contains(builtInUUID) {
            return builtInUUID
        }
        if let primaryUUID, available.contains(primaryUUID) {
            return primaryUUID
        }
        return availableUUIDs.first
    }
}
