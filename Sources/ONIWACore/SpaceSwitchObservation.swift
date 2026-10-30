/// Interprets a synthetic Space-switch step using the *entire* display layout.
/// Checking only the destination display is unsafe: macOS may route synthetic
/// Mission Control input to a different display than the cursor's position.
public enum SpaceSwitchObservation {
    public enum Outcome: Equatable {
        case waiting
        case confirmed
        case wrongTarget
        case otherDisplayChanged
        case displayUnavailable
    }

    public static func evaluate(targetDisplay: String, beforeTarget: UInt64,
                                expectedTarget: UInt64, beforeOthers: [String: UInt64],
                                after: [String: UInt64]) -> Outcome {
        guard let target = after[targetDisplay] else { return .displayUnavailable }
        for (display, previous) in beforeOthers {
            guard let current = after[display] else { return .displayUnavailable }
            if current != previous { return .otherDisplayChanged }
        }
        if target == expectedTarget { return .confirmed }
        if target != beforeTarget { return .wrongTarget }
        return .waiting
    }
}
