import Foundation

/// Deterministic, entirely local ranking. No network requests or AI required.
public enum FuzzySearch {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func score(query: String, fields: [String]) -> Int? {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let normalizedFields = fields.map(normalized)
        var total = 0
        for token in tokens {
            let scores = normalizedFields.compactMap { field -> Int? in
                if field == token { return 120 }
                if field.hasPrefix(token) { return 100 - min(30, field.count - token.count) }
                if field.contains(token) { return 70 - min(20, field.count - token.count) }
                var chars = field.makeIterator()
                var matched = 0
                for letter in token {
                    while let next = chars.next() {
                        if next == letter { matched += 1; break }
                    }
                    if matched < token.count && matched <= 0 { break }
                }
                // Subsequence match tolerates omitted characters, not arbitrary typos.
                return matched == token.count ? 30 : nil
            }
            guard let best = scores.max() else { return nil }
            total += best
        }
        return total
    }

    public static func sorted<T>(_ items: [T], query: String,
                                 fields: (T) -> [String]) -> [T] {
        items.enumerated()
            .compactMap { index, item -> (Int, Int, T)? in
                guard let rank = score(query: query, fields: fields(item)) else { return nil }
                return (rank, index, item)
            }
            .sorted { left, right in
                left.0 == right.0 ? left.1 < right.1 : left.0 > right.0
            }
            .map { $0.2 }
    }
}
