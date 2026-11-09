import Foundation

/// Preferred scroll viewport for the Space name/tag editor. This is only a
/// height estimate for presentation; its contents must remain scrollable so
/// text scaling, localization and narrow screens never clip app tiles.
public enum SpaceEditorLayout {
    /// One detected-app tile needs space for its icon, label and touch target.
    /// Do not allow the app grid to be compressed to a partial icon row.
    public static let minimumAppGridHeight: CGFloat = 82

    public static func scrollHeight(tagCount: Int,
                                    appCount: Int,
                                    isSessionOnly: Bool,
                                    availableScreenHeight: CGFloat) -> CGFloat {
        // Title, text fields, labels, help and vertical spacing.
        let commonContent: CGFloat = 210
        // Tags occupy a horizontal row only when at least one is present.
        let tagRow: CGFloat = tagCount > 0 ? 42 : 0

        // Show up to three detected-app rows without scrolling on a large
        // display. Additional rows stay available in the outer ScrollView.
        let visibleRows = min(3, (max(0, appCount) + 2) / 3)
        let appSection: CGFloat = appCount > 0
            ? 62 + CGFloat(visibleRows) * minimumAppGridHeight : 0
        let sessionWarning: CGFloat = isSessionOnly ? 38 : 0
        let preferred = max(245, commonContent + tagRow + appSection + sessionWarning)

        // Leave room for the anchored footer, sheet padding, title bar and
        // a little vertical breathing space on the containing monitor.
        let screenLimit = max(180, availableScreenHeight - 160)
        return min(preferred, screenLimit)
    }
}
