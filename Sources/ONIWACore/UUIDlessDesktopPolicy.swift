import Foundation

/// A single live Space record from the read-only SkyLight display topology.
/// Keep the distinction between a present-but-empty UUID and a missing field:
/// only the former is the macOS primary-desktop special case.
public struct SpaceUUIDRecord {
    public let kind: Int
    public let rawUUID: String?

    public init(kind: Int, rawUUID: String?) {
        self.kind = kind
        self.rawUUID = rawUUID
    }
}

/// macOS can report the original desktop's UUID as "". Do not substitute its
/// mutable position or ManagedSpaceID as a persistent key. Only a single,
/// explicitly empty UUID on one display is eligible for a special anchor.
/// An absent/unreadable UUID, or multiple UUID-less Spaces, fails closed.
public enum UUIDlessDesktopPolicy {
    public static func anchorIndex(in records: [SpaceUUIDRecord]) -> Int? {
        let withoutUUID = records.indices.filter {
            guard let raw = records[$0].rawUUID else { return true }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard withoutUUID.count == 1, let index = withoutUUID.first,
              records[index].kind == 0,
              let raw = records[index].rawUUID,
              raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return index
    }
}
