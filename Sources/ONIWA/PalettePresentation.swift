import AppKit
import SwiftUI
import ONIWACore

/// Presentation-only tokens shared by the five palette presets.
/// Use system colors/materials so light/dark appearance and accessibility
/// contrast remain legible; no OS-version-specific Liquid Glass dependency.
/// The chosen design never changes query/order, Space UUIDs or navigation.
extension PaletteDesign {
    var panelSize: CGSize {
        switch self {
        case .nativeCalm: return CGSize(width: 520, height: 450)
        case .frostedFocus: return CGSize(width: 540, height: 470)
        case .commandCompact: return CGSize(width: 480, height: 370)
        case .studioCards: return CGSize(width: 580, height: 530)
        case .monitorFocus: return CGSize(width: 560, height: 490)
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .commandCompact: return 12
        case .studioCards: return 20
        default: return 17
        }
    }

    var stackSpacing: CGFloat {
        switch self {
        case .commandCompact: return 7
        case .studioCards: return 14
        default: return 11
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .commandCompact: return 1
        case .studioCards: return 10
        case .frostedFocus: return 7
        case .monitorFocus: return 6
        case .nativeCalm: return 4
        }
    }

    var rowHorizontalPadding: CGFloat {
        switch self {
        case .commandCompact: return 7
        case .studioCards: return 13
        case .monitorFocus: return 11
        default: return 10
        }
    }

    var rowVerticalPadding: CGFloat {
        switch self {
        case .commandCompact: return 5
        case .studioCards: return 13
        case .frostedFocus: return 11
        case .monitorFocus: return 9
        case .nativeCalm: return 9
        }
    }

    var rowCornerRadius: CGFloat {
        switch self {
        case .commandCompact: return 5
        case .nativeCalm: return 9
        case .frostedFocus: return 15
        case .studioCards: return 15
        case .monitorFocus: return 11
        }
    }

    var leadingIconWidth: CGFloat {
        switch self {
        case .studioCards: return 31
        case .commandCompact: return 16
        default: return 22
        }
    }

    var titleFont: Font {
        switch self {
        case .studioCards: return .system(size: 15, weight: .medium)
        case .commandCompact: return .system(size: 12, weight: .regular)
        case .monitorFocus: return .system(size: 14, weight: .medium)
        default: return .system(size: 13, weight: .regular)
        }
    }

    var headingFont: Font {
        switch self {
        case .studioCards: return .system(size: 21, weight: .semibold, design: .rounded)
        case .frostedFocus: return .system(size: 19, weight: .semibold, design: .rounded)
        case .commandCompact: return .system(size: 13, weight: .bold)
        default: return .system(size: 16, weight: .semibold)
        }
    }

    var searchFont: Font {
        switch self {
        case .commandCompact: return .system(size: 13)
        case .studioCards: return .system(size: 16)
        default: return .system(size: 15)
        }
    }

    var selectedOpacity: Double {
        switch self {
        case .commandCompact: return 0.19
        case .studioCards: return 0.12
        case .frostedFocus: return 0.12
        default: return 0.15
        }
    }

    var idleColor: Color {
        switch self {
        case .studioCards: return Color(nsColor: .controlBackgroundColor)
        case .frostedFocus: return Color.secondary.opacity(0.07)
        case .monitorFocus: return Color.secondary.opacity(0.045)
        default: return .clear
        }
    }

    var canvasColor: Color {
        switch self {
        case .commandCompact: return Color(nsColor: .controlBackgroundColor)
        case .studioCards: return Color(nsColor: .underPageBackgroundColor)
        default: return Color(nsColor: .windowBackgroundColor)
        }
    }

    var hasMaterialSurface: Bool { self == .frostedFocus }
    var showsMonitorBadge: Bool { self == .monitorFocus }
    var showsSubtitle: Bool {
        self == .frostedFocus || self == .studioCards || self == .monitorFocus
    }
}
