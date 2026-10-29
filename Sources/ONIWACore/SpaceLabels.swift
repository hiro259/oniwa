import Foundation

/// A Space's numeric ID identifies it while it exists; the UUID is the only
/// identity we trust for persistence across launches. Neither its position
/// nor a fullscreen app name is a safe persistent identity.
public struct SpaceIdentity: Hashable {
    public let displayID: String
    public let managedID: UInt64
    public let uuid: String?

    public init(displayID: String, managedID: UInt64, uuid: String?) {
        self.displayID = displayID
        self.managedID = managedID
        let normalized = uuid?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.uuid = (normalized?.isEmpty == false) ? normalized : nil
    }

    /// Used for UI selection only. Moving a Space in Mission Control does not
    /// change this ID. Do not write it as a persisted user label key.
    public var runtimeKey: String {
        "runtime:\(displayID):\(managedID)"
    }

    /// Scoped by monitor, so a duplicate UUID on a different display cannot
    /// accidentally inherit that monitor's name.
    public var persistentKey: String? {
        guard let uuid else { return nil }
        return "space.v2:\(displayID):\(uuid)"
    }

    /// v1 stored UUIDs without a monitor scope. A v1 label is eligible for
    /// migration only when its UUID is unique among currently visible Spaces.
    public var legacyUUIDKey: String? {
        guard let uuid else { return nil }
        return "uuid:\(uuid)"
    }
}

public struct SpaceLabel: Codable, Equatable {
    public var name: String
    public var aliases: String

    public init(name: String, aliases: String) {
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.aliases = String(aliases.trimmingCharacters(in: .whitespacesAndNewlines).prefix(250))
    }

    public var isEmpty: Bool { name.isEmpty && aliases.isEmpty }
}

/// Persists only identities backed by a nonempty Space UUID. For Spaces with
/// no UUID, names are useful only for this running ONIWA process and are
/// explicitly discarded at launch rather than migrating across Space reorder.
public final class SpaceLabelStore {
    private static let v2Key = "oniwa.customLabels.v2"
    private static let v1Key = "oniwa.customLabels.v1"
    private let defaults: UserDefaults
    private var stored: [String: SpaceLabel]
    private var sessionOnly: [String: SpaceLabel] = [:]
    private let legacy: [String: SpaceLabel]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.v2Key),
           let decoded = try? JSONDecoder().decode([String: SpaceLabel].self, from: data) {
            stored = decoded
        } else {
            stored = [:]
        }
        if let data = defaults.data(forKey: Self.v1Key),
           let decoded = try? JSONDecoder().decode([String: SpaceLabel].self, from: data) {
            legacy = decoded
        } else {
            legacy = [:]
        }
    }

    public func label(for identity: SpaceIdentity) -> SpaceLabel? {
        if let key = identity.persistentKey { return stored[key] }
        return sessionOnly[identity.runtimeKey]
    }

    public func update(_ identity: SpaceIdentity, name: String, aliases: String) {
        let label = SpaceLabel(name: name, aliases: aliases)
        if let key = identity.persistentKey {
            if label.isEmpty { stored.removeValue(forKey: key) }
            else { stored[key] = label }
            persist()
        } else {
            if label.isEmpty { sessionOnly.removeValue(forKey: identity.runtimeKey) }
            else { sessionOnly[identity.runtimeKey] = label }
        }
    }

    /// Invoked on every full refresh (not switching polls).
    /// - Removes transient names for Spaces which disappeared.
    /// - Migrates only unambiguous UUID-based v1 labels.
    /// - Deliberately ignores v1's "position:..." entries, which could now
    ///   refer to completely different Spaces after reordering.
    public func reconcile(_ identities: [SpaceIdentity]) {
        let liveRuntimeKeys = Set(identities.map(\.runtimeKey))
        sessionOnly = sessionOnly.filter { liveRuntimeKeys.contains($0.key) }

        let counts = identities.reduce(into: [String: Int]()) { counts, identity in
            if let uuid = identity.uuid { counts[uuid, default: 0] += 1 }
        }
        var migrated = false
        for identity in identities {
            guard let uuid = identity.uuid, counts[uuid] == 1,
                  let key = identity.persistentKey, stored[key] == nil,
                  let legacyKey = identity.legacyUUIDKey,
                  let previous = legacy.first(where: {
                      $0.key.lowercased() == legacyKey
                  })?.value, !previous.isEmpty else { continue }
            stored[key] = previous
            migrated = true
        }
        if migrated { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.v2Key)
    }
}
