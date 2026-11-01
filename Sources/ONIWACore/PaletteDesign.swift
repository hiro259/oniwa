import Foundation

/// Stable IDs for the eight ONIWA visual presets. This is presentation state:
/// neither Space identities nor switcher settings depend on these values.
public enum PaletteDesign: String, CaseIterable, Identifiable {
    case nativeCalm
    case frostedFocus
    case commandCompact
    case studioCards
    case monitorFocus
    case modernPrecision
    case pureMonochrome
    case macOSNative

    public static let settingsKey = "oniwa.paletteDesign"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nativeCalm: return "Native Calm"
        case .frostedFocus: return "Frosted Focus"
        case .commandCompact: return "Command Compact"
        case .studioCards: return "Studio Cards"
        case .monitorFocus: return "Monitor Focus"
        case .modernPrecision: return "Modern Precision"
        case .pureMonochrome: return "Pure Monochrome"
        case .macOSNative: return "macOS Native"
        }
    }

    public var detail: String {
        switch self {
        case .nativeCalm: return AppLanguage.ui("macOSに馴染む、静かな標準スタイル", "Quiet, familiar macOS style")
        case .frostedFocus: return AppLanguage.ui("透け感のある、軽やかな検索パレット", "Soft, translucent search palette")
        case .commandCompact: return AppLanguage.ui("情報密度とキーボード操作を最優先", "Compact, keyboard-first interface")
        case .studioCards: return AppLanguage.ui("作業環境をゆったりと見渡すカード", "Spacious workspace cards")
        case .monitorFocus: return AppLanguage.ui("モニターと2画面セットを明確に表示", "Emphasis on displays and paired Spaces")
        case .modernPrecision: return AppLanguage.ui("上質なグレーと繊細なガラス質感", "Subtle gray tones and glass effects")
        case .pureMonochrome: return AppLanguage.ui("余白と文字だけで整えたミニマルなUI", "Minimal layout, focused on typography")
        case .macOSNative: return AppLanguage.ui("すりガラスと余白を活かしたmacOS純正風パレット", "Native-inspired glass and whitespace")
        }
    }

    public static func selected(in defaults: UserDefaults = .standard) -> PaletteDesign {
        guard let raw = defaults.string(forKey: settingsKey),
              let design = PaletteDesign(rawValue: raw) else { return .nativeCalm }
        return design
    }

    public func persist(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.settingsKey)
    }
}
