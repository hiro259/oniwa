/// Determines if a *single* Mission Control AX session may safely complete
/// with ordinary keyboard switching. The UI overlay may publish temporary
/// Space IDs, so this policy is used only after Mission Control has closed.
///
/// This decision never retries an AXPress and never guesses a destination.
/// A missing/wrong/changed Space or an unrelated monitor change aborts.
public enum MissionControlPairExperimentPolicy {
    public enum Decision: Equatable {
        case complete
        case keyboard([String])
        case abort
    }

    public static func decide(
        firstDisplay: String,
        secondDisplay: String,
        before: [String: UInt64],
        targets: [String: UInt64],
        firstSample: [String: UInt64],
        secondSample: [String: UInt64],
        rosterStable: Bool,
        missionControlClosed: Bool
    ) -> Decision {
        guard missionControlClosed, rosterStable,
              firstDisplay != secondDisplay,
              let firstStart = before[firstDisplay],
              let secondStart = before[secondDisplay],
              let firstTarget = targets[firstDisplay],
              let secondTarget = targets[secondDisplay],
              !before.isEmpty,
              Set(firstSample.keys) == Set(before.keys),
              Set(secondSample.keys) == Set(before.keys),
              firstSample == secondSample else { return .abort }

        let allowed: [String: (UInt64, UInt64)] = [
            firstDisplay: (firstStart, firstTarget),
            secondDisplay: (secondStart, secondTarget)
        ]
        for (display, original) in before {
            guard let observed = secondSample[display] else { return .abort }
            if let pair = allowed[display] {
                guard observed == pair.0 || observed == pair.1 else { return .abort }
            } else if observed != original {
                return .abort
            }
        }
        let remaining = [firstDisplay, secondDisplay].filter {
            secondSample[$0] != targets[$0]
        }
        return remaining.isEmpty ? .complete : .keyboard(remaining)
    }
}
