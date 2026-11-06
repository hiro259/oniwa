import Foundation

/// A Space's numeric ID identifies it while it exists; regular persistence
/// uses its UUID. macOS's original desktop may instead have a unique empty
/// UUID: that case receives an explicit display-scoped anchor from the reader.
/// Neither an index nor a numeric ManagedSpaceID is ever stored as identity.
public struct SpaceIdentity: Hashable {
    public let displayID: String
    public let managedID: UInt64
    public let uuid: String?
    /// Only SpaceReader may opt in after verifying exactly one blank-UUID
    /// normal desktop on this display. Other UUID-less spaces stay transient.
    public let isUUIDlessDesktopAnchor: Bool

    public init(displayID: String, managedID: UInt64, uuid: String?,
                isUUIDlessDesktopAnchor: Bool = false) {
        self.displayID = displayID
        self.managedID = managedID
        let normalized = uuid?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.uuid = (normalized?.isEmpty == false) ? normalized : nil
        self.isUUIDlessDesktopAnchor = self.uuid == nil && isUUIDlessDesktopAnchor
    }

    /// Used for UI selection only. Moving a Space in Mission Control does not
    /// change this ID. Do not write it as a persisted user label key.
    public var runtimeKey: String {
        "runtime:\(displayID):\(managedID)"
    }

    /// Scoped by monitor, so duplicates on other displays cannot inherit data.
    /// The unique blank-UUID desktop has its own key namespace, never a made-up
    /// UUID (which would accidentally become a valid target for saved sets).
    public var persistentKey: String? {
        if let uuid { return "space.v2:\(displayID):\(uuid)" }
        if isUUIDlessDesktopAnchor {
            return "space.uuidless-primary.v1:\(displayID)"
        }
        return nil
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
    /// Previous ONIWA versions saved space-delimited aliases in this field.
    /// Preserve it for decoding existing v1/v2 labels.
    public var aliases: String
    /// New labels use an array so "web development" can be ONE tag.
    /// Nil means the record predates structured tags; [] means no tags.
    public var tags: [String]?

    public init(name: String, aliases: String, tags: [String]? = nil) {
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.aliases = String(aliases.trimmingCharacters(in: .whitespacesAndNewlines).prefix(250))
        self.tags = tags.map(Self.cleanedTags)
    }

    /// A one-way, nondestructive view of legacy aliases; the first edit saves
    /// structured tags. Unedited labels still retain their original data.
    public var searchTags: [String] {
        tags ?? FuzzySearch.keywords(in: aliases)
    }

    public static func cleanedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for value in raw {
            var tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.hasPrefix("#") || tag.hasPrefix("＃") { tag.removeFirst() }
            tag = String(tag.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !tag.isEmpty else { continue }
            if seen.insert(FuzzySearch.normalized(tag)).inserted {
                tags.append(tag)
            }
        }
        return tags
    }

    public var isEmpty: Bool { name.isEmpty && searchTags.isEmpty }
}

/// Persists UUID-backed identities and the explicitly recognized unique
/// blank-UUID desktop on each display. Other missing-UUID spaces receive
/// session-only names and never inherit labels based on their position.
public final class SpaceLabelStore {
    private static let v2Key = "oniwa.customLabels.v2"
    private static let v1Key = "oniwa.customLabels.v1"
    private let defaults: UserDefaults
    private var stored: [String: SpaceLabel]
    private var sessionOnly: [String: SpaceLabel] = [:]
    private var legacy: [String: SpaceLabel]

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
        write(identity, label: SpaceLabel(name: name, aliases: aliases))
    }

    /// New save path; spaces are valid WITHIN a tag.
    public func update(_ identity: SpaceIdentity, name: String, tags: [String]) {
        write(identity, label: SpaceLabel(name: name, aliases: "", tags: tags))
    }

    private func write(_ identity: SpaceIdentity, label: SpaceLabel) {
        if let key = identity.persistentKey {
            if label.isEmpty { stored.removeValue(forKey: key) }
            else { stored[key] = label }
            persist()
            // Do not resurrect a previously saved v1 label after the user
            // deletes or overrides its v2 replacement.
            if let legacyKey = identity.legacyUUIDKey {
                let oldKeys = legacy.keys.filter { $0.lowercased() == legacyKey }
                if !oldKeys.isEmpty {
                    for oldKey in oldKeys { legacy.removeValue(forKey: oldKey) }
                    if let data = try? JSONEncoder().encode(legacy) {
                        defaults.set(data, forKey: Self.v1Key)
                    }
                }
            }
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
                  let old = legacy.first(where: {
                      $0.key.lowercased() == legacyKey
                  }), !old.value.isEmpty else { continue }
            stored[key] = old.value
            // Consume this migration record so clearing the new label cannot
            // resurrect it on the next refresh or application launch.
            legacy.removeValue(forKey: old.key)
            migrated = true
        }
        if migrated {
            persist()
            if let data = try? JSONEncoder().encode(legacy) {
                defaults.set(data, forKey: Self.v1Key)
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.v2Key)
    }
}
