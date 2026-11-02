import Foundation

/// User-facing UI language; saved Space names and tags are never translated.
/// An absent or automatic preference follows the Mac's primary language.
/// Explicit Japanese/English choices continue to override system preferences.
public enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    public static let settingsKey = "oniwa.interfaceLanguage"
    public static let automaticValue = "system"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }

    public func text(_ japanese: String, _ english: String) -> String {
        self == .english ? english : japanese
    }

    /// The user's highest-priority macOS language determines the UI language.
    /// Japanese (ja, ja-JP, ja_JP) uses Japanese; everything else uses English.
    /// Injecting the list makes behavior deterministic in tests.
    public static func systemPreferred(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard let primary = preferredLanguages.first?
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first?
            .lowercased() else { return .english }
        return primary == "ja" ? .japanese : .english
    }

    /// Resolve raw @AppStorage values without persisting a synthesized default.
    /// Old manual ja/en settings are never modified by a system-language change.
    public static func effective(
        rawValue: String?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let rawValue, let manual = AppLanguage(rawValue: rawValue) {
            return manual
        }
        return systemPreferred(preferredLanguages: preferredLanguages)
    }

    public static func isFollowingSystem(in defaults: UserDefaults = .standard) -> Bool {
        let raw = defaults.string(forKey: settingsKey)
        return raw.flatMap(AppLanguage.init(rawValue:)) == nil
    }

    public static func selected(
        in defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        effective(rawValue: defaults.string(forKey: settingsKey),
                  preferredLanguages: preferredLanguages)
    }

    /// Only an explicit UI selection persists a manual language override.
    public func persist(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.settingsKey)
    }

    /// A concrete automatic sentinel notifies @AppStorage while preserving
    /// the distinction between manual and automatic language preferences.
    public static func followSystem(in defaults: UserDefaults = .standard) {
        defaults.set(automaticValue, forKey: settingsKey)
    }

    public static func ui(_ japanese: String, _ english: String) -> String {
        selected().text(japanese, english)
    }
}
