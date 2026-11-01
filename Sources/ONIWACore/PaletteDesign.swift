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
        case .nativeCalm: return "macOSに馴染む、静かな標準スタイル"
        case .frostedFocus: return "透け感のある、軽やかな検索パレット"
        case .commandCompact: return "情報密度とキーボード操作を最優先"
        case .studioCards: return "作業環境をゆったりと見渡すカード"
        case .monitorFocus: return "モニターと2画面セットを明確に表示"
        case .modernPrecision: return "上質なグレーと繊細なガラス質感"
        case .pureMonochrome: return "余白と文字だけで整えたミニマルなUI"
        case .macOSNative: return "すりガラスと余白を活かしたmacOS純正風パレット"
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
