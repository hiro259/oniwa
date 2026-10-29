/// Pure routing rules for ONIWA-only fast Spaces switching.
///
/// Unknown macOS releases deliberately stay on the proven keyboard path until
/// their gesture payloads have been checked on real hardware.
public enum InstantSwitchPolicy {
    public enum FallbackDecision: Equatable {
        case keyboard
        case alreadySwitched
        case abort
    }

    public static func supportsInstant(major: Int, minor: Int) -> Bool {
        major == 27 || (major == 26 && minor >= 6)
    }

    /// After a fast gesture timed out, only emit the normal keyboard shortcut
    /// if the expected transition really did not occur and the Space order is
    /// unchanged. Never emit a second movement after an unexpected switch.
    public static func fallbackDecision(
        previous: UInt64, expected: UInt64,
        observed: UInt64?, orderUnchanged: Bool
    ) -> FallbackDecision {
        guard orderUnchanged, let observed else { return .abort }
        if observed == expected { return .alreadySwitched }
        if observed == previous { return .keyboard }
        return .abort
    }
}
