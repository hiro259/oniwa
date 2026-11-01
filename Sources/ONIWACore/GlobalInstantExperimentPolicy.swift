/// Pure routing for the opt-in, global gesture experiment.
/// The single/pair 3-choice preferences remain stored and unchanged.
public enum GlobalInstantExperimentPolicy {
    public static func singleMode(
        enabled: Bool, selected: SingleSpaceSwitchMode
    ) -> SingleSpaceSwitchMode {
        enabled ? .instant : selected
    }

    public static func usesHybrid(
        enabled: Bool, selected: PairSpaceSwitchMode
    ) -> Bool {
        !enabled && selected == .hybrid
    }

    /// One set activation is one operation. After any confirmed keyboard
    /// fallback, *all remaining steps of that operation* use the keyboard.
    /// The flag is local to the operation and resets on the next invocation.
    public static func pairStepMode(
        enabled: Bool, selected: PairSpaceSwitchMode,
        hadGestureFallback: Bool
    ) -> SingleSpaceSwitchMode {
        if enabled {
            return hadGestureFallback ? .keyboard : .instant
        }
        return selected == .missionControlTwice ? .missionControl : .keyboard
    }
}
