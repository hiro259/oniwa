import Foundation
import ONIWACore

/// A single persisted value per UI group replaces the old overlapping
/// Boolean mode toggles. Readers also use a deterministic legacy fallback
/// before app launch has completed the one-time migration.
enum SwitchModeSettings {
    static let singleKey = "oniwa.singleSpaceSwitchMode"
    static let pairKey = "oniwa.pairSpaceSwitchMode"

    static var single: SingleSpaceSwitchMode {
        get {
            if let value = UserDefaults.standard.string(forKey: singleKey),
               let mode = SingleSpaceSwitchMode(rawValue: value) {
                return mode
            }
            return SwitchModeMigration.single(
                instant: InstantSwitchSettings.enabled,
                missionControl: MissionControlDirectSettings.enabled)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: singleKey) }
    }

    static var pair: PairSpaceSwitchMode {
        get {
            if let value = UserDefaults.standard.string(forKey: pairKey),
               let mode = PairSpaceSwitchMode(rawValue: value) {
                return mode
            }
            return SwitchModeMigration.pair(
                missionControl: MissionControlDirectSettings.enabled,
                hybrid: MissionControlPairHybridSettings.enabled)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: pairKey) }
    }

    /// Copy the effective old settings once. If only one group was previously
    /// migrated, retain it and migrate the other independently. Neither a
    /// legacy fast gesture flag nor the failed one-session experiment can
    /// silently override an explicit new selection.
    static func migrateLegacySettingsIfNeeded() {
        let defaults = UserDefaults.standard
        if SingleSpaceSwitchMode(rawValue: defaults.string(forKey: singleKey) ?? "") == nil {
            single = SwitchModeMigration.single(
                instant: InstantSwitchSettings.enabled,
                missionControl: MissionControlDirectSettings.enabled)
        }
        if PairSpaceSwitchMode(rawValue: defaults.string(forKey: pairKey) ?? "") == nil {
            pair = SwitchModeMigration.pair(
                missionControl: MissionControlDirectSettings.enabled,
                hybrid: MissionControlPairHybridSettings.enabled)
        }
        // This experiment accepted two AXPress calls but often moved only one
        // display. Keep it unreachable even if an old preference was saved.
        MissionControlPairSingleSessionSettings.enabled = false
    }
}
