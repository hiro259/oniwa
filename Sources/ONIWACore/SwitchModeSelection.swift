/// Explicit, mutually exclusive user-facing choices. Single Space selection
/// and two-display Space set selection are independent.
public enum SingleSpaceSwitchMode: String, CaseIterable {
    case keyboard
    case instant
    case missionControl
}

public enum PairSpaceSwitchMode: String, CaseIterable {
    case keyboard
    case hybrid
    case missionControlTwice
}

/// Readable and testable migration from the older independent Boolean toggles.
/// An obsolete "two AX presses in one Mission Control session" experiment is
/// deliberately NOT a selectable mode: it failed on an actual two-display Mac.
public enum SwitchModeMigration {
    public static func single(instant: Bool, missionControl: Bool)
        -> SingleSpaceSwitchMode {
        if missionControl { return .missionControl }
        return instant ? .instant : .keyboard
    }

    public static func pair(missionControl: Bool, hybrid: Bool)
        -> PairSpaceSwitchMode {
        if missionControl { return hybrid ? .hybrid : .missionControlTwice }
        // Two-display keyboard mode uses ordinary Ctrl+Arrow, *not* the
        // unreliable fast Dock gesture even when it was previously enabled.
        return .keyboard
    }
}
