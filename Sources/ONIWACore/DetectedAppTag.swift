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

    /// Use the same normalized comparison for both the added indicator and
    /// removal. This also matches tags created manually with different casing.
    public static func matchingIndex(of appName: String, in tags: [String]) -> Int? {
        guard let tag = tagName(from: appName) else { return nil }
        let target = FuzzySearch.normalized(tag)
        return tags.firstIndex { FuzzySearch.normalized($0) == target }
    }

    public static func isAdded(_ appName: String, to tags: [String]) -> Bool {
        matchingIndex(of: appName, in: tags) != nil
    }

    /// Idempotent under case/width/diacritic variations; preserves existing
    /// tags' original spelling and insertion order.
    public static func adding(_ appName: String, to tags: [String]) -> [String] {
        guard let tag = tagName(from: appName) else { return tags }
        return SpaceLabel.cleanedTags(tags + [tag])
    }
}
