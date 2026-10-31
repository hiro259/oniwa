import Foundation

public enum SpaceListSortMode: String, Codable, CaseIterable {
    case recent
    case original
    case name
    case custom
}

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
        // Optional for decoding the v1 snapshot without losing pins or MRU.
        var sortMode: SpaceListSortMode?
        var customOrder: [String]?
    }

    private let defaults: UserDefaults
    private var pinned: [String] = []
    private var recent: [String] = []
    private var customOrder: [String] = []
    public private(set) var sortMode: SpaceListSortMode = .recent

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        pinned = Self.deduplicated(saved.pinned)
        recent = Array(Self.deduplicated(saved.recent).prefix(Self.maximumRecentEntries))
        sortMode = saved.sortMode ?? .recent
        customOrder = Self.deduplicated(saved.customOrder ?? [])
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
        customOrder.removeAll { $0 == key }
        persist()
    }

    /// Changing modes does not discard an existing manual order.
    /// The first entry into custom mode starts from the currently shown order.
    public func setSortMode(_ mode: SpaceListSortMode, visibleKeys: [String]) {
        if mode == .custom && customOrder.isEmpty {
            customOrder = Self.deduplicated(visibleKeys)
        }
        sortMode = mode
        persist()
    }

    /// Move a visible row into position. Pinned items can be reordered among
    /// pins, and ordinary items among ordinary items; dragging cannot silently
    /// pin/unpin a row. A drop on the row below moves after it.
    @discardableResult
    public func moveCustom(_ source: String, to target: String,
                           visibleKeys: [String]) -> Bool {
        guard sortMode == .custom, source != target, !source.isEmpty, !target.isEmpty,
              visibleKeys.contains(source), visibleKeys.contains(target) else { return false }
        let sourcePinned = isPinned(source)
        guard sourcePinned == isPinned(target) else { return false }
        if sourcePinned {
            guard Self.move(source, to: target, in: &pinned) else { return false }
        } else {
            // Preserve hidden/disconnected keys already in the custom layout.
            for key in visibleKeys where !customOrder.contains(key) {
                customOrder.append(key)
            }
            guard Self.move(source, to: target, in: &customOrder) else { return false }
        }
        persist()
        return true
    }

    private static func move(_ source: String, to target: String,
                             in keys: inout [String]) -> Bool {
        guard let a = keys.firstIndex(of: source),
              let b = keys.firstIndex(of: target) else { return false }
        let value = keys.remove(at: a)
        let newIndex = keys.firstIndex(of: target)!
        keys.insert(value, at: a < b ? newIndex + 1 : newIndex)
        return true
    }

    /// Pinned entries always come first. When a query is active, the unpinned
    /// portion keeps its incoming fuzzy-search rank, regardless of mode.
    /// Original order comes from the supplied keys (pairs then macOS Spaces).
    public func orderedKeys(_ keys: [String], useRecency: Bool = true,
                            names: [String: String] = [:]) -> [String] {
        let mode = useRecency ? sortMode : .original
        let pins = Dictionary(uniqueKeysWithValues: pinned.enumerated().map {
            ($0.element, $0.offset)
        })
        let usage = Dictionary(uniqueKeysWithValues: recent.enumerated().map {
            ($0.element, $0.offset)
        })
        let manual = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map {
            ($0.element, $0.offset)
        })
        return keys.enumerated().sorted { left, right in
            let a = left.element
            let b = right.element
            let aPin = pins[a]
            let bPin = pins[b]
            if aPin != nil || bPin != nil {
                if let aPin, let bPin { return aPin < bPin }
                return aPin != nil
            }
            switch mode {
            case .recent:
                let aRank = usage[a], bRank = usage[b]
                if aRank != nil || bRank != nil {
                    if let aRank, let bRank { return aRank < bRank }
                    return aRank != nil
                }
            case .name:
                let aName = FuzzySearch.normalized(names[a] ?? a)
                let bName = FuzzySearch.normalized(names[b] ?? b)
                let order = aName.localizedStandardCompare(bName)
                if order != .orderedSame { return order == .orderedAscending }
            case .custom:
                let aRank = manual[a], bRank = manual[b]
                if aRank != nil || bRank != nil {
                    if let aRank, let bRank { return aRank < bRank }
                    return aRank != nil
                }
            case .original:
                break
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(pinned: pinned, recent: recent,
                                                    sortMode: sortMode,
                                                    customOrder: customOrder))
        else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
