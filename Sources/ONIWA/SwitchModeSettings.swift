import Foundation
import ONIWACore

/// A single persisted value per UI group replaces the old overlapping
/// Boolean mode toggles. Readers also use a deterministic legacy fallback
/// before app launch has completed the one-time migration.
enum DesktopNumberExperimentMode: String {
    case off
    case rapid
    case sequential
}

enum ArrowBurstExperimentMode: String {
    case off
    case ms100
    case ms50

    var intervalMS: Int {
        switch self {
        case .off, .ms100: return 100
        case .ms50: return 50
        }
    }
}

enum SwitchModeSettings {
    static let arrowBurstModeKey = "oniwa.arrowBurstExperimentMode"

    static var arrowBurstExperimentMode: ArrowBurstExperimentMode {
        get {
            ArrowBurstExperimentMode(
                rawValue: UserDefaults.standard.string(forKey: arrowBurstModeKey) ?? ""
            ) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: arrowBurstModeKey)
            if newValue != .off {
                UserDefaults.standard.set(false, forKey: globalInstantExperimentKey)
                UserDefaults.standard.set(false, forKey: globalMCOneSessionExperimentKey)
                UserDefaults.standard.set(DesktopNumberExperimentMode.off.rawValue,
                                          forKey: desktopNumberModeKey)
            }
        }
    }
    static let desktopNumberModeKey = "oniwa.desktopNumberExperimentMode"

    static var desktopNumberExperimentMode: DesktopNumberExperimentMode {
        get {
            DesktopNumberExperimentMode(
                rawValue: UserDefaults.standard.string(forKey: desktopNumberModeKey) ?? ""
            ) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: desktopNumberModeKey)
            if newValue != .off {
                UserDefaults.standard.set(false, forKey: globalInstantExperimentKey)
                UserDefaults.standard.set(false, forKey: globalMCOneSessionExperimentKey)
                UserDefaults.standard.set(ArrowBurstExperimentMode.off.rawValue,
                                          forKey: arrowBurstModeKey)
            }
        }
    }
    static let singleKey = "oniwa.singleSpaceSwitchMode"
    static let pairKey = "oniwa.pairSpaceSwitchMode"

    /// Global, separately persisted experiment. When ON it overrides both
    /// independent 3-choice menus, without replacing their saved selections.
    /// The flag is never disabled by an individual failed gesture.
    static let globalInstantExperimentKey = "oniwa.globalInstantExperimentEnabled"

    /// Distinct from the retired legacy MC-one-session preference; this
    /// experiment records AX timings and verifies safe partial fallback.
    static let globalMCOneSessionExperimentKey = "oniwa.mcOneSessionDiagnosticExperimentEnabled"
    static let mcReversePressOrderKey = "oniwa.mcOneSessionReversePressOrder"

    static var globalInstantExperimentEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: globalInstantExperimentKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: globalInstantExperimentKey)
            if newValue {
                UserDefaults.standard.set(false, forKey: globalMCOneSessionExperimentKey)
                UserDefaults.standard.set(DesktopNumberExperimentMode.off.rawValue,
                                          forKey: desktopNumberModeKey)
                UserDefaults.standard.set(ArrowBurstExperimentMode.off.rawValue,
                                          forKey: arrowBurstModeKey)
            }
        }
    }

    static var globalMCOneSessionExperimentEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: globalMCOneSessionExperimentKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: globalMCOneSessionExperimentKey)
            if newValue {
                UserDefaults.standard.set(false, forKey: globalInstantExperimentKey)
                UserDefaults.standard.set(DesktopNumberExperimentMode.off.rawValue,
                                          forKey: desktopNumberModeKey)
                UserDefaults.standard.set(ArrowBurstExperimentMode.off.rawValue,
                                          forKey: arrowBurstModeKey)
            }
        }
    }

    /// False: first saved Space before second; true: second before first.
    /// A/B testing is manual so individual trials are not silently alternated.
    static var mcReversePressOrder: Bool {
        get { UserDefaults.standard.bool(forKey: mcReversePressOrderKey) }
        set { UserDefaults.standard.set(newValue, forKey: mcReversePressOrderKey) }
    }

    static var anyGlobalExperimentEnabled: Bool {
        globalInstantExperimentEnabled || globalMCOneSessionExperimentEnabled
            || desktopNumberExperimentMode != .off
            || arrowBurstExperimentMode != .off
    }

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
