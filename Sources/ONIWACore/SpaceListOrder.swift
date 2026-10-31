import Foundation

/// User-controlled order of Space search results.
///
/// Keys must be stable: monitor-scoped Space UUIDs or persisted pair UUIDs.
/// Transient managed Space IDs are never written to disk. The pin list keeps
/// its insertion order; recently used entries are most-recent-first.
public final class SpaceListOrderStore {
    private static let storageKey = "oniwa.spaceListOrder.v1"
    private static let maximumRecentEntries = 200

    private struct Snapshot: Codable {
        var pinned: [String]
        var recent: [String]
    }

    private let defaults: UserDefaults
    private var pinned: [String] = []
    private var recent: [String] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        pinned = Self.deduplicated(saved.pinned)
        recent = Array(Self.deduplicated(saved.recent).prefix(Self.maximumRecentEntries))
    }

    private static func deduplicated(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func isPinned(_ key: String) -> Bool {
        pinned.contains(key)
    }

    /// Return the new pin status. Re-pinning puts the entry after existing pins.
    @discardableResult
    public func togglePin(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        if let index = pinned.firstIndex(of: key) {
            pinned.remove(at: index)
            persist()
            return false
        }
        pinned.append(key)
        persist()
        return true
    }

    /// Called only when a switch is confirmed or when an observed Space
    /// transition changes the current ID. Merely opening search does not count.
    public func markUsed(_ key: String) {
        guard !key.isEmpty else { return }
        if recent.first == key { return }
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        if recent.count > Self.maximumRecentEntries {
            recent.removeLast(recent.count - Self.maximumRecentEntries)
        }
        persist()
    }

    /// Clean up a deleted pair so reusing the same persisted UUID cannot
    /// inherit an old pin or history.
    public func remove(_ key: String) {
        pinned.removeAll { $0 == key }
        recent.removeAll { $0 == key }
        persist()
    }

    /// Keep original order as a deterministic fallback for never-used items.
    /// During search, caller can choose to preserve fuzzy rank for unpinned
    /// rows, while still showing matching pins first.
    public func orderedKeys(_ keys: [String], useRecency: Bool = true) -> [String] {
        let pinPositions = Dictionary(uniqueKeysWithValues: pinned.enumerated().map {
            ($0.element, $0.offset)
        })
        let recentPositions = Dictionary(uniqueKeysWithValues: recent.enumerated().map {
            ($0.element, $0.offset)
        })
        return keys.enumerated().sorted { left, right in
            let a = left.element
            let b = right.element
            let aPin = pinPositions[a]
            let bPin = pinPositions[b]
            if aPin != nil || bPin != nil {
                if let aPin, let bPin { return aPin < bPin }
                return aPin != nil
            }
            if useRecency {
                let aRecent = recentPositions[a]
                let bRecent = recentPositions[b]
                if aRecent != nil || bRecent != nil {
                    if let aRecent, let bRecent { return aRecent < bRecent }
                    return aRecent != nil
                }
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(pinned: pinned, recent: recent))
        else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
