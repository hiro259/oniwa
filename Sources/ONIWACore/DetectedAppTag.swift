import Foundation

/// Turning an automatically detected app into a manual search tag is always
/// an explicit user action in the Space editor. This only updates the draft;
/// the caller must still save the edited label to persist it.
public enum DetectedAppTag {
    /// Preserve multi-word app names. Apply the same cleaning as manual tags,
    /// while refusing invalid process names that contain control characters.
    public static func tagName(from appName: String) -> String? {
        guard !appName.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        return SpaceLabel.cleanedTags([appName]).first
    }

    public static func isAdded(_ appName: String, to tags: [String]) -> Bool {
        guard let tag = tagName(from: appName) else { return false }
        let target = FuzzySearch.normalized(tag)
        return tags.contains { FuzzySearch.normalized($0) == target }
    }

    /// Idempotent under case/width/diacritic variations; preserves existing
    /// tags' original spelling and insertion order.
    public static func adding(_ appName: String, to tags: [String]) -> [String] {
        guard let tag = tagName(from: appName) else { return tags }
        return SpaceLabel.cleanedTags(tags + [tag])
    }
}
