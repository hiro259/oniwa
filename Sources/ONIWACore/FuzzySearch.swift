import Foundation

/// A query searches a Space's displayed name, user keywords, apps and display
/// without treating all of those sources as equally informative.
public struct SearchField {
    public enum Kind {
        case name
        case keyword
        case defaultName
        case app
        case display

        fileprivate var priority: Int {
            switch self {
            case .name: return 60
            case .keyword: return 55
            case .defaultName: return 25
            case .app: return 15
            case .display: return 5
            }
        }
    }

    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

/// Deterministic, entirely local ranking. No network requests or AI required.
public enum FuzzySearch {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Existing alias strings stay in the store unchanged. Search treats
    /// whitespace, # and common comma/semicolon separators as keyword breaks:
    /// "shumi chrome", "#shumi #chrome" and "shumi,chrome" are equivalent.
    public static func keywords(in aliases: String) -> [String] {
        let parts = normalized(aliases).split(whereSeparator: isKeywordSeparator)
        var seen = Set<String>()
        return parts.map(String.init).filter { seen.insert($0).inserted }
    }

    private static func isKeywordSeparator(_ character: Character) -> Bool {
        character.isWhitespace
            || character == "#" || character == "＃"
            || character == "," || character == "，" || character == "、"
            || character == ";" || character == "；"
    }

    private static func queryTokens(_ query: String) -> [String] {
        normalized(query).split(whereSeparator: isKeywordSeparator).map(String.init)
    }

    private static func matchScore(token: String, field: String) -> Int? {
        guard !field.isEmpty else { return nil }
        if field == token { return 1200 }
        let excess = min(80, max(0, field.count - token.count))
        if field.hasPrefix(token) { return 900 - excess }

        // "chrome" finds "Google Chrome" even though it is not at the start.
        let words = field.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(token) }) { return 720 - excess }
        if field.contains(token) { return 500 - excess }

        // Ordered subsequence tolerates omitted letters, not random typos.
        var nextIndex = field.startIndex
        for letter in token {
            guard let found = field[nextIndex...].firstIndex(of: letter) else { return nil }
            nextIndex = field.index(after: found)
        }
        return 220 - min(80, max(0, field.count - token.count))
    }

    private static func rankedScore(query: String, fields: [SearchField]) -> Int? {
        let tokens = queryTokens(query)
        if tokens.isEmpty {
            return normalized(query).isEmpty ? 0 : nil
        }

        let prepared = fields.map { (normalized($0.text), $0.kind.priority) }
        var total = 0
        for token in tokens {
            let matches = prepared.compactMap { field, priority -> Int? in
                guard let score = matchScore(token: token, field: field) else { return nil }
                return score + priority
            }
            guard let best = matches.max() else { return nil }
            total += best
        }
        return total
    }

    /// Kept for existing callers; fields have the same priority.
    public static func score(query: String, fields: [String]) -> Int? {
        rankedScore(query: query, fields: fields.map {
            SearchField(text: $0, kind: .defaultName)
        })
    }

    private static func order<T>(_ items: [T], score: (T) -> Int?) -> [T] {
        items.enumerated()
            .compactMap { index, item -> (Int, Int, T)? in
                guard let rank = score(item) else { return nil }
                return (rank, index, item)
            }
            .sorted { left, right in
                left.0 == right.0 ? left.1 < right.1 : left.0 > right.0
            }
            .map { $0.2 }
    }

    public static func sorted<T>(_ items: [T], query: String,
                                 fields: (T) -> [String]) -> [T] {
        order(items) { score(query: query, fields: fields($0)) }
    }

    /// User names and explicitly registered keywords break ties over app or
    /// monitor matches. Matching still favors exact > prefix > word > fuzzy.
    public static func ranked<T>(_ items: [T], query: String,
                                 fields: (T) -> [SearchField]) -> [T] {
        order(items) { rankedScore(query: query, fields: fields($0)) }
    }
}
