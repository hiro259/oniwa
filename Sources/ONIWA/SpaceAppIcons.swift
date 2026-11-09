import AppKit
import SwiftUI

/// Icon lookup is presentation-only. Missing apps are shown as blank icons
/// and never affect Space discovery, matching, or switching.
@MainActor
private final class SpaceAppIconCache {
    static let shared = SpaceAppIconCache()
    private let images = NSCache<NSNumber, NSImage>()
    private var unavailable = Set<pid_t>()

    private init() {
        images.countLimit = 128
    }

    func icon(for pid: pid_t?) -> NSImage? {
        guard let pid, pid > 0 else { return nil }
        let key = NSNumber(value: pid)
        if let cached = images.object(forKey: key) { return cached }
        if unavailable.contains(pid) { return nil }

        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            unavailable.insert(pid)
            return nil
        }
        // A normal app icon is preferable to a guessed match by process name.
        let result = runningApp.icon
            ?? runningApp.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        if let result {
            images.setObject(result, forKey: key)
        } else {
            unavailable.insert(pid)
        }
        return result
    }
}

@MainActor
struct SpaceAppIcon: View {
    let app: SpaceApp
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = SpaceAppIconCache.shared.icon(for: app.processIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // Neutral blank: no inaccurate guessed icon or extra permission.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.60), lineWidth: 1.35)
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Compact app name and icon shown beneath an individual or paired Space.
@MainActor
struct SpaceAppChip: View {
    let app: SpaceApp
    var size: CGFloat = 21

    var body: some View {
        HStack(spacing: 4) {
            SpaceAppIcon(app: app, size: size)
            Text(app.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 105, alignment: .leading)
        .help(app.name)
    }
}

/// An interactive detected app tile in the Space editor. The surrounding
/// Button performs the tag operation; this view only indicates its state.
@MainActor
struct SpaceAppTile: View {
    let app: SpaceApp
    let isTagged: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                SpaceAppIcon(app: app, size: 38)
                if isTagged {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                        .offset(x: 5, y: -4)
                        .accessibilityHidden(true)
                }
            }
            Text(app.name)
                .font(.caption2)
                .foregroundStyle(isTagged ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isTagged ? Color.accentColor.opacity(0.12)
                    : (isHovered ? Color.secondary.opacity(0.10) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name)
    }
}
