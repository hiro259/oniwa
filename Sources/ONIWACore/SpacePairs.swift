import Foundation

/// A pair never refers to a desktop by its number or the transient numeric
/// Space ID. macOS can reorder and recreate those at any moment.
public struct SpacePairTarget: Codable, Hashable {
    public let displayID: String
    public let uuid: String

    public init?(identity: SpaceIdentity) {
        guard let uuid = identity.uuid else { return nil }
        displayID = identity.displayID
        self.uuid = uuid
    }

    public var persistentKey: String { "space.v2:\(displayID):\(uuid)" }
}

public struct SpacePair: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var first: SpacePairTarget
    public var second: SpacePairTarget

    public init(id: UUID = UUID(), name: String, first: SpacePairTarget,
                second: SpacePairTarget) {
        self.id = id
        self.name = Self.cleanedName(name)
        self.first = first
        self.second = second
    }

    public static func cleanedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
}

public enum SpacePairResolver {
    /// A valid pair always contains distinct display UUIDs, not two Spaces on
    /// one monitor. This deliberately excludes session-only Space identities.
    public static func valid(_ pair: SpacePair) -> Bool {
        !pair.name.isEmpty && pair.first.displayID != pair.second.displayID
            && !pair.first.uuid.isEmpty && !pair.second.uuid.isEmpty
    }

    /// Resolve *both* before any keyboard or swipe event is sent. Duplicate or
    /// missing UUIDs are rejected rather than guessed from desktop positions.
    public static func resolve(_ pair: SpacePair, in live: [SpaceIdentity])
        -> (SpaceIdentity, SpaceIdentity)? {
        guard valid(pair) else { return nil }
        let first = live.filter { $0.persistentKey == pair.first.persistentKey }
        let second = live.filter { $0.persistentKey == pair.second.persistentKey }
        guard first.count == 1, second.count == 1 else { return nil }
        return (first[0], second[0])
    }
}

/// Separate from individual Space names/tags. A disappeared target stays in
/// the saved pair as "unavailable": it must NEVER silently map to a new Space.
public final class SpacePairStore {
    private static let key = "oniwa.spacePairs.v1"
    private let defaults: UserDefaults
    public private(set) var pairs: [SpacePair] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SpacePair].self, from: data) {
            var ids = Set<UUID>()
            pairs = decoded.filter { SpacePairResolver.valid($0) && ids.insert($0.id).inserted }
        }
    }

    @discardableResult
    public func save(_ pair: SpacePair) -> Bool {
        guard SpacePairResolver.valid(pair) else { return false }
        if let index = pairs.firstIndex(where: { $0.id == pair.id }) {
            pairs[index] = pair
        } else {
            pairs.append(pair)
        }
        persist()
        return true
    }

    public func delete(id: UUID) {
        pairs.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pairs) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
