/// Mission Control's Accessibility overlay can temporarily expose different
/// Current Space IDs on *both* displays, even when a thumbnail press targets
/// only one display. During the pending/arrival phase, those values are NOT
/// reliable evidence that a different display was switched.
///
/// Unlike a synthetic Ctrl+Arrow gesture, a direct AXPress is only issued once.
/// We must wait for its target to arrive, then validate every display after
/// macOS has settled, before attempting another move in a two-display set.
public enum MissionControlDirectObservation {
    public enum Arrival: Equatable {
        case waiting
        case arrived
        case displayUnavailable
    }

    public enum Settled: Equatable {
        case confirmed
        case wrongTarget
        case otherDisplayChanged
        case displayUnavailable
    }

    /// Intermediate IDs, including a different Space on the target display,
    /// are provisional while Mission Control is animating. A later 3-second
    /// timeout rejects a target that never arrives.
    public static func arrival(targetDisplay: String, expectedTarget: UInt64,
                               after: [String: UInt64]) -> Arrival {
        guard let actual = after[targetDisplay] else { return .displayUnavailable }
        return actual == expectedTarget ? .arrived : .waiting
    }

    /// This check must run *after* the 850ms post-arrival settle delay.
    /// A different Space on another monitor is never accepted as success.
    public static func settled(targetDisplay: String, expectedTarget: UInt64,
                               beforeOthers: [String: UInt64],
                               after: [String: UInt64]) -> Settled {
        guard let actual = after[targetDisplay] else { return .displayUnavailable }
        for (display, previous) in beforeOthers {
            guard let current = after[display] else { return .displayUnavailable }
            if current != previous { return .otherDisplayChanged }
        }
        return actual == expectedTarget ? .confirmed : .wrongTarget
    }
}
