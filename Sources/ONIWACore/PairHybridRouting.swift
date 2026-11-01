/// Plan a two-display mixed-mode switch based on physical display roles.
/// Pair registration order is NOT a routing rule: the built-in display always
/// uses Mission Control, and the external display always uses keyboard steps.
public struct PairHybridRoute: Equatable {
    public let builtInDisplayID: String
    public let externalDisplayID: String

    public init(builtInDisplayID: String, externalDisplayID: String) {
        self.builtInDisplayID = builtInDisplayID
        self.externalDisplayID = externalDisplayID
    }
}

public enum PairHybridRouting {
    /// The keys in `isBuiltInByDisplayID` are live physical display UUIDs.
    /// Returns nil for ambiguous/missing/duplicate roles, rather than routing
    /// keyboard input to the wrong monitor (e.g. external-only clamshell).
    public static func resolve(
        firstDisplayID: String, secondDisplayID: String,
        isBuiltInByDisplayID: [String: Bool]
    ) -> PairHybridRoute? {
        let firstKey = firstDisplayID.lowercased()
        let secondKey = secondDisplayID.lowercased()
        guard firstKey != secondKey else { return nil }

        var roles: [String: Bool] = [:]
        for (id, isBuiltIn) in isBuiltInByDisplayID {
            let key = id.lowercased()
            guard roles[key] == nil else { return nil }
            roles[key] = isBuiltIn
        }
        guard let firstIsBuiltIn = roles[firstKey],
              let secondIsBuiltIn = roles[secondKey],
              firstIsBuiltIn != secondIsBuiltIn else { return nil }
        return firstIsBuiltIn
            ? PairHybridRoute(builtInDisplayID: firstDisplayID,
                              externalDisplayID: secondDisplayID)
            : PairHybridRoute(builtInDisplayID: secondDisplayID,
                              externalDisplayID: firstDisplayID)
    }
}
