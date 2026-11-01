/// Pure decisions for the experimental single-session, two-monitor
/// Mission Control switch. Current Space IDs can be provisional while the
/// Mission Control overlay is visible; verify unrelated monitors at settle.
public enum MissionControlPairObservation {
    public enum Arrival: Equatable {
        case waiting
        case arrived
    }

    public enum Settled: Equatable {
        case confirmed
        case incorrectTarget
        case unrelatedDisplayChanged
        case displayUnavailable
    }

    public static func arrival(
        firstDisplay: String, firstTarget: UInt64,
        secondDisplay: String, secondTarget: UInt64,
        current: [String: UInt64]
    ) -> Arrival {
        guard firstDisplay != secondDisplay else { return .waiting }
        return current[firstDisplay] == firstTarget
            && current[secondDisplay] == secondTarget ? .arrived : .waiting
    }

    public static func settled(
        firstDisplay: String, firstTarget: UInt64,
        secondDisplay: String, secondTarget: UInt64,
        untouched: [String: UInt64], current: [String: UInt64]
    ) -> Settled {
        guard firstDisplay != secondDisplay,
              let first = current[firstDisplay],
              let second = current[secondDisplay] else { return .displayUnavailable }
        for (display, originalID) in untouched {
            guard let actual = current[display] else { return .displayUnavailable }
            if actual != originalID { return .unrelatedDisplayChanged }
        }
        return first == firstTarget && second == secondTarget
            ? .confirmed : .incorrectTarget
    }
}
