import Foundation

/// User-facing UI language; saved Space names and tags are never translated.
/// Default Japanese preserves the app's existing behavior for current users.
public enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    public static let settingsKey = "oniwa.interfaceLanguage"

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

    public static func selected(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let raw = defaults.string(forKey: settingsKey),
              let value = AppLanguage(rawValue: raw) else { return .japanese }
        return value
    }

    public func persist(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.settingsKey)
    }

    public static func ui(_ japanese: String, _ english: String) -> String {
        selected().text(japanese, english)
    }
}
