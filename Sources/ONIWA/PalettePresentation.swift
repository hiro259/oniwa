import AppKit
import SwiftUI
import ONIWACore

/// Presentation-only tokens shared by the eight palette presets.
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
        case .modernPrecision: return CGSize(width: 555, height: 490)
        case .pureMonochrome: return CGSize(width: 510, height: 455)
        case .macOSNative: return CGSize(width: 535, height: 465)
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .commandCompact: return 12
        case .studioCards: return 20
        case .modernPrecision: return 19
        case .pureMonochrome: return 22
        case .macOSNative: return 20
        default: return 17
        }
    }

    var stackSpacing: CGFloat {
        switch self {
        case .commandCompact: return 7
        case .studioCards: return 14
        case .modernPrecision: return 13
        case .pureMonochrome: return 14
        case .macOSNative: return 12
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
        case .modernPrecision: return 7
        case .pureMonochrome: return 3
        case .macOSNative: return 2
        }
    }

    var rowHorizontalPadding: CGFloat {
        switch self {
        case .commandCompact: return 7
        case .studioCards: return 13
        case .monitorFocus: return 11
        case .modernPrecision: return 14
        case .pureMonochrome: return 12
        case .macOSNative: return 11
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
        case .modernPrecision: return 12
        case .pureMonochrome: return 11
        case .macOSNative: return 10
        }
    }

    var rowCornerRadius: CGFloat {
        switch self {
        case .commandCompact: return 5
        case .nativeCalm: return 9
        case .frostedFocus: return 15
        case .studioCards: return 15
        case .monitorFocus: return 11
        case .modernPrecision: return 14
        case .pureMonochrome: return 8
        case .macOSNative: return 9
        }
    }

    var leadingIconWidth: CGFloat {
        switch self {
        case .studioCards: return 31
        case .commandCompact: return 16
        case .modernPrecision: return 24
        case .pureMonochrome: return 20
        case .macOSNative: return 20
        default: return 22
        }
    }

    var titleFont: Font {
        switch self {
        case .studioCards: return .system(size: 15, weight: .medium)
        case .commandCompact: return .system(size: 12, weight: .regular)
        case .monitorFocus: return .system(size: 14, weight: .medium)
        case .modernPrecision: return .system(size: 14, weight: .medium)
        case .pureMonochrome: return .system(size: 14, weight: .regular)
        case .macOSNative: return .system(size: 14, weight: .medium)
        default: return .system(size: 13, weight: .regular)
        }
    }

    var headingFont: Font {
        switch self {
        case .studioCards: return .system(size: 21, weight: .semibold, design: .rounded)
        case .frostedFocus: return .system(size: 19, weight: .semibold, design: .rounded)
        case .commandCompact: return .system(size: 13, weight: .bold)
        case .modernPrecision: return .system(size: 17, weight: .semibold)
        case .pureMonochrome: return .system(size: 16, weight: .semibold)
        case .macOSNative: return .system(size: 16, weight: .semibold)
        default: return .system(size: 16, weight: .semibold)
        }
    }

    var searchFont: Font {
        switch self {
        case .commandCompact: return .system(size: 13)
        case .studioCards: return .system(size: 16)
        case .modernPrecision: return .system(size: 15)
        case .pureMonochrome: return .system(size: 15)
        default: return .system(size: 15)
        }
    }

    var selectedOpacity: Double {
        switch self {
        case .commandCompact: return 0.19
        case .studioCards: return 0.12
        case .frostedFocus: return 0.12
        case .modernPrecision: return 0.10
        case .pureMonochrome: return 0.07
        case .macOSNative: return 0.08
        default: return 0.15
        }
    }

    var idleColor: Color {
        switch self {
        case .studioCards: return Color(nsColor: .controlBackgroundColor)
        case .frostedFocus: return Color.secondary.opacity(0.07)
        case .monitorFocus: return Color.secondary.opacity(0.045)
        case .modernPrecision: return Color.secondary.opacity(0.035)
        case .pureMonochrome: return .clear
        case .macOSNative: return .clear
        default: return .clear
        }
    }

    var canvasColor: Color {
        switch self {
        case .commandCompact: return Color(nsColor: .controlBackgroundColor)
        case .studioCards: return Color(nsColor: .underPageBackgroundColor)
        case .modernPrecision: return Color(nsColor: .windowBackgroundColor)
        case .pureMonochrome: return Color(nsColor: .windowBackgroundColor)
        default: return Color(nsColor: .windowBackgroundColor)
        }
    }

    var hasMaterialSurface: Bool { self == .frostedFocus }
    var isRefined: Bool {
        self == .modernPrecision || self == .pureMonochrome || self == .macOSNative
    }
    var controlAccent: Color {
        self == .modernPrecision ? Color(red: 0.35, green: 0.40, blue: 0.68) : .accentColor
    }
    var showsMonitorBadge: Bool { self == .monitorFocus }
    var showsSubtitle: Bool {
        self == .frostedFocus || self == .studioCards || self == .monitorFocus
            || self == .modernPrecision
    }
}


/// A native search-field silhouette without a heavy blue focus ring or stroke.
/// The control uses a subtle semantic fill, with no card or border decoration.
struct MacOSNativeSearchSurface: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(isFocused ? 0.70 : 0.52),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

/// A reserved inline space for editing actions. It never changes row width
/// when the pointer enters; only visual opacity and hit testing change.
struct PaletteHoverActions: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .animation(.easeInOut(duration: 0.16), value: isVisible)
    }
}

/// Replaces AppKit's thick blue text-field focus ring for refined
/// designs. The macOS Native preset has a separate borderless treatment.
struct RefinedSearchSurface: ViewModifier {
    let design: PaletteDesign
    let isFocused: Bool

    private var radius: CGFloat { design == .modernPrecision ? 12 : 8 }

    @ViewBuilder
    func body(content: Content) -> some View {
        if design == .macOSNative {
            content.modifier(MacOSNativeSearchSurface(isFocused: isFocused))
        } else {
        content
            .padding(.horizontal, 13)
            .padding(.vertical, design == .modernPrecision ? 12 : 11)
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(design == .modernPrecision
                          ? Color(nsColor: .controlBackgroundColor).opacity(0.82)
                          : Color.secondary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        isFocused
                            ? (design == .modernPrecision
                               ? design.controlAccent.opacity(0.38)
                               : Color.primary.opacity(0.34))
                            : Color.secondary.opacity(design == .modernPrecision ? 0.20 : 0.12),
                        lineWidth: 1)
            }
            .shadow(color: design == .modernPrecision && isFocused
                    ? design.controlAccent.opacity(0.13) : .clear,
                    radius: 9, y: 1)
            .shadow(color: design == .modernPrecision
                    ? Color.black.opacity(0.045) : .clear,
                    radius: 6, y: 2)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Identical switching/selection semantics for all eight themes. Only the
/// decorative surface changes. Refined themes animate hover and selection,
/// while "current" remains distinguishable from keyboard focus.
struct PaletteRowSurface: ViewModifier {
    let design: PaletteDesign
    let isSelected: Bool
    let isCurrent: Bool
    let isHovered: Bool

    private var active: Bool { isSelected || isHovered }

    private var fill: LinearGradient {
        let stops: [Color]
        switch design {
        case .modernPrecision:
            if isSelected {
                stops = [design.controlAccent.opacity(0.11),
                         design.controlAccent.opacity(0.055)]
            } else if isHovered {
                stops = [Color.secondary.opacity(0.095),
                         Color.secondary.opacity(0.045)]
            } else if isCurrent {
                stops = [Color.secondary.opacity(0.07),
                         Color.secondary.opacity(0.03)]
            } else {
                stops = [Color.primary.opacity(0.027),
                         Color.primary.opacity(0.012)]
            }
        case .pureMonochrome:
            let opacity = isSelected ? 0.105 : (isHovered ? 0.055 : (isCurrent ? 0.035 : 0))
            stops = [Color.secondary.opacity(opacity), Color.secondary.opacity(opacity)]
        case .macOSNative:
            // No resting cards: only an understated selection/hover affordance.
            let opacity = isSelected ? 0.09 : (isHovered ? 0.04 : 0)
            stops = [Color.primary.opacity(opacity), Color.primary.opacity(opacity)]
        default:
            let color = isSelected ? Color.accentColor.opacity(design.selectedOpacity)
                : (isCurrent ? Color.secondary.opacity(0.055) : design.idleColor)
            stops = [color, color]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var stroke: Color {
        if design == .modernPrecision {
            if isSelected { return design.controlAccent.opacity(0.20) }
            if isCurrent { return Color.secondary.opacity(0.22) }
            return Color.secondary.opacity(isHovered ? 0.16 : 0.075)
        }
        if design == .pureMonochrome || design == .macOSNative { return .clear }
        return isCurrent ? Color.secondary.opacity(0.40) : .clear
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: design.rowCornerRadius)
                    .fill(fill)
            }
            .clipShape(RoundedRectangle(cornerRadius: design.rowCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: design.rowCornerRadius)
                    .strokeBorder(stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                if (design == .pureMonochrome || design == .macOSNative) && isSelected {
                    Capsule()
                        .fill(design.controlAccent)
                        .frame(width: 2, height: 21)
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: design == .modernPrecision && active
                    ? Color.black.opacity(0.065) : .clear,
                    radius: 6, y: 2)
            .animation(.easeInOut(duration: 0.16), value: isSelected)
            .animation(.easeInOut(duration: 0.16), value: isHovered)
    }
}
